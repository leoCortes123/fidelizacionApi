-- =====================================================================
-- Flujo de venta con QR por negocio
--
-- Se recupera el flujo original: en caja se introduce el valor de la compra
-- y se genera un QR con un identificador. El cliente escanea el QR, confirma
-- la compra y los puntos se acreditan en SU cuenta (afiliándose al negocio
-- si todavía no lo estaba). No se asignan puntos manualmente a un usuario.
--
-- Cambios:
--   1. `purchases.business_id`: la compra pertenece a un negocio.
--   2. `private.accrue_purchase_points`: lógica de acumulación reutilizable
--      (staff y cliente). `points_accrue_from_purchase` pasa a ser la
--      variante autorizada para staff.
--   3. `purchase_qr_create`: genera la venta pendiente y su token.
--   4. `purchase_qr_preview`: consulta pública del QR (antes de iniciar sesión).
--   5. `purchase_qr_claim`: el cliente confirma y recibe los puntos.
--   6. `business_purchases_list` y `purchase_qr_cancel`: historial y anulación
--      de las ventas del negocio.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. La compra queda asociada al negocio que la generó
-- ---------------------------------------------------------------------
alter table public.purchases
  add column if not exists business_id uuid references public.businesses (id) on delete cascade;

create index if not exists purchases_business_created_idx
  on public.purchases (business_id, created_at desc);

comment on column public.purchases.business_id is
  'Negocio que generó el QR. NULL en compras del flujo legado global.';

-- ---------------------------------------------------------------------
-- 2. Acumulación reutilizable (misma regla que la registración por staff)
--
-- La lógica vivía dentro de `points_accrue_from_purchase`, que exige rol
-- admin/encargado. El cliente que reclama su QR también debe acumular, así
-- que se extrae a una función interna sin chequeo de rol y ambas rutas
-- comparten exactamente la misma regla (incluidas campañas vigentes).
-- ---------------------------------------------------------------------
create or replace function private.accrue_purchase_points(
  p_business_id uuid,
  p_account_id uuid,
  p_purchase_id uuid,
  p_amount_cop integer,
  p_eligible_amount_cop integer,
  p_idempotency_key text,
  p_created_by uuid,
  p_rule_version text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_program public.loyalty_programs;
  v_campaign public.loyalty_campaigns;
  v_account public.loyalty_point_accounts;
  v_event public.loyalty_purchase_events;
  v_base_points integer;
  v_points integer;
  v_tx public.loyalty_point_transactions;
  v_balance bigint;
  v_rule text;
begin
  if p_amount_cop is null or p_amount_cop <= 0 then
    raise exception 'invalid_amount';
  end if;
  if p_eligible_amount_cop is null or p_eligible_amount_cop < 0
     or p_eligible_amount_cop > p_amount_cop then
    raise exception 'invalid_eligible_amount';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9:_-]{8,120}$' then
    raise exception 'invalid_idempotency_key';
  end if;

  select * into v_account
    from public.loyalty_point_accounts
   where id = p_account_id and business_id = p_business_id;

  if not found then
    raise exception 'account_not_found';
  end if;

  -- Idempotencia por clave: no duplicar movimiento ni evento.
  select * into v_tx
    from public.loyalty_point_transactions
   where idempotency_key = p_idempotency_key;

  if found then
    if v_tx.business_id <> p_business_id or v_tx.account_id <> p_account_id then
      raise exception 'idempotency_key_conflict';
    end if;
    select * into v_event
      from public.loyalty_purchase_events
     where business_id = p_business_id
       and idempotency_key = p_idempotency_key;
    select coalesce(sum(points), 0) into v_balance
      from public.loyalty_point_transactions
     where account_id = p_account_id;
    return jsonb_build_object(
      'points_earned', 0,
      'balance', v_balance,
      'duplicate', true,
      'purchase_event_id', v_event.id,
      'message', 'La compra ya fue procesada.'
    );
  end if;

  -- Idempotencia del evento: cubre las compras que generaron 0 puntos.
  select * into v_event
    from public.loyalty_purchase_events
   where business_id = p_business_id
     and idempotency_key = p_idempotency_key;

  if found then
    select coalesce(sum(points), 0) into v_balance
      from public.loyalty_point_transactions
     where account_id = p_account_id;
    return jsonb_build_object(
      'points_earned', 0,
      'balance', v_balance,
      'duplicate', true,
      'purchase_event_id', v_event.id,
      'message', 'La compra ya fue procesada.'
    );
  end if;

  -- Evitar duplicar puntos al reprocesar una misma compra (flujo QR o staff).
  if p_purchase_id is not null then
    select * into v_event
      from public.loyalty_purchase_events
     where purchase_id = p_purchase_id;

    if found then
      select coalesce(sum(points), 0) into v_balance
        from public.loyalty_point_transactions
       where account_id = p_account_id;
      return jsonb_build_object(
        'points_earned', 0,
        'balance', v_balance,
        'duplicate', true,
        'purchase_event_id', v_event.id,
        'message', 'La compra ya fue procesada.'
      );
    end if;
  end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found or not v_program.is_active then
    raise exception 'program_not_active';
  end if;

  v_base_points := floor(p_eligible_amount_cop::numeric / v_program.cop_per_point_unit)::integer;

  -- Campaña vigente con mayor beneficio (solo si cumple la compra mínima).
  select * into v_campaign
    from public.loyalty_campaigns c
   where c.business_id = p_business_id
     and c.is_active
     and c.valid_from <= now()
     and (c.valid_until is null or c.valid_until > now())
     and p_eligible_amount_cop >= c.min_purchase_amount
   order by c.multiplier desc, c.bonus_points desc, c.created_at desc
   limit 1;

  if found then
    v_points := floor(v_base_points * greatest(coalesce(v_campaign.multiplier, 1), 1))::integer
                + greatest(coalesce(v_campaign.bonus_points, 0), 0);
  else
    v_points := v_base_points;
  end if;

  v_points := least(greatest(v_points, 0), 1000000);

  v_rule := coalesce(p_rule_version, 'v1');
  if v_campaign.id is not null then
    v_rule := v_rule || '+campaign:' || v_campaign.id::text;
  end if;

  if v_points > 0 then
    perform public.loyalty_transaction_post(
      p_business_id,
      p_account_id,
      'purchase_credit'::public.point_movement_type,
      v_points,
      'purchase'::text,
      p_purchase_id,
      format('Compra %s COP elegibles %s COP (regla %s%s)',
             p_amount_cop, p_eligible_amount_cop, v_rule,
             case when v_campaign.id is not null
                  then format(' · %s x%s +%s', v_campaign.name, v_campaign.multiplier, v_campaign.bonus_points)
                  else '' end)::text,
      p_idempotency_key::text,
      p_created_by
    );
  end if;

  insert into public.loyalty_purchase_events (
    business_id, account_id, purchase_id, amount_cop,
    eligible_amount_cop, points_earned, rule_version, idempotency_key
  ) values (
    p_business_id, p_account_id, p_purchase_id, p_amount_cop,
    p_eligible_amount_cop, v_points, v_rule, p_idempotency_key
  )
  returning * into v_event;

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  return jsonb_build_object(
    'points_earned', v_points,
    'balance', v_balance,
    'duplicate', false,
    'purchase_event_id', v_event.id,
    'base_points', v_base_points,
    'campaign_id', v_campaign.id,
    'campaign_name', v_campaign.name,
    'multiplier', coalesce(v_campaign.multiplier, 1),
    'bonus_points', coalesce(v_campaign.bonus_points, 0)
  );
end;
$$;

revoke execute on function private.accrue_purchase_points(
  uuid, uuid, uuid, integer, integer, text, uuid, text
) from public;
revoke execute on function private.accrue_purchase_points(
  uuid, uuid, uuid, integer, integer, text, uuid, text
) from anon;
revoke execute on function private.accrue_purchase_points(
  uuid, uuid, uuid, integer, integer, text, uuid, text
) from authenticated;

-- `points_accrue_from_purchase` mantiene su firma y su control de rol.
create or replace function public.points_accrue_from_purchase(
  p_business_id uuid,
  p_account_id uuid,
  p_purchase_id uuid,
  p_amount_cop integer,
  p_eligible_amount_cop integer,
  p_idempotency_key text,
  p_created_by uuid,
  p_rule_version text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  return private.accrue_purchase_points(
    p_business_id, p_account_id, p_purchase_id, p_amount_cop,
    p_eligible_amount_cop, p_idempotency_key, v_uid, p_rule_version
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Generar el QR de una venta
-- ---------------------------------------------------------------------
create or replace function public.purchase_qr_create(
  p_business_id uuid,
  p_amount_cop integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_business public.businesses;
  v_program public.loyalty_programs;
  v_campaign public.loyalty_campaigns;
  v_token text;
  v_purchase_id uuid;
  v_expires_at timestamptz;
  v_base_points integer;
  v_points_preview integer := 0;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  select * into v_business
    from public.businesses
   where id = p_business_id and is_active;

  if not found then raise exception 'business_not_found'; end if;

  if p_amount_cop is null or p_amount_cop <= 0 then
    raise exception 'amount_invalid';
  end if;
  if p_amount_cop > 50000000 then
    raise exception 'amount_too_large';
  end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found or not v_program.is_active then
    raise exception 'program_not_active';
  end if;

  v_base_points := floor(p_amount_cop::numeric / v_program.cop_per_point_unit)::integer;

  select * into v_campaign
    from public.loyalty_campaigns c
   where c.business_id = p_business_id
     and c.is_active
     and c.valid_from <= now()
     and (c.valid_until is null or c.valid_until > now())
     and p_amount_cop >= c.min_purchase_amount
   order by c.multiplier desc, c.bonus_points desc, c.created_at desc
   limit 1;

  if found then
    v_points_preview := floor(v_base_points * greatest(coalesce(v_campaign.multiplier, 1), 1))::integer
                        + greatest(coalesce(v_campaign.bonus_points, 0), 0);
  else
    v_points_preview := v_base_points;
  end if;
  v_points_preview := least(greatest(v_points_preview, 0), 1000000);

  perform private.consume_rate_limit('purchase_qr_create:' || v_uid::text, 60, 60);

  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_expires_at := now() + make_interval(hours => v_program.qr_expiry_hours);

  insert into public.purchases (
    business_id, amount_cop, registrar_id, token_hash, expires_at, settings_snapshot
  ) values (
    p_business_id,
    p_amount_cop,
    v_uid,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    v_expires_at,
    jsonb_build_object(
      'cop_per_point_unit', v_program.cop_per_point_unit,
      'qr_expiry_hours', v_program.qr_expiry_hours,
      'points_expiry_days', v_program.points_expiry_days,
      'program_updated_at', v_program.updated_at
    )
  )
  returning id into v_purchase_id;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'purchase.qr_created',
    'purchase',
    v_purchase_id::text,
    jsonb_build_object(
      'amount_cop', p_amount_cop,
      'points_preview', v_points_preview,
      'expires_at', v_expires_at
    )
  );

  return jsonb_build_object(
    'purchase_id', v_purchase_id,
    'token', v_token,
    'business_id', v_business.id,
    'business_name', v_business.name,
    'amount_cop', p_amount_cop,
    'points_preview', v_points_preview,
    'expires_at', v_expires_at,
    'status', 'pending_claim'
  );
end;
$$;

grant execute on function public.purchase_qr_create(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Consulta pública del QR (antes de iniciar sesión)
--
-- El token es el secreto: quien lo tiene puede ver el negocio, el importe y
-- los puntos estimados. No expone datos del cliente ni el hash guardado.
-- ---------------------------------------------------------------------
create or replace function public.purchase_qr_preview(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_purchase public.purchases;
  v_business public.businesses;
  v_program public.loyalty_programs;
  v_campaign public.loyalty_campaigns;
  v_points integer;
  v_status public.purchase_status;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  perform private.consume_rate_limit(
    'purchase_qr_preview:' || left(encode(extensions.digest(p_token, 'sha256'), 'hex'), 24),
    60, 60
  );

  select * into v_purchase
    from public.purchases
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and business_id is not null;

  if not found then
    raise exception 'invalid_token';
  end if;

  select * into v_business
    from public.businesses
   where id = v_purchase.business_id;

  select * into v_program
    from public.loyalty_programs
   where business_id = v_purchase.business_id;

  v_status := v_purchase.status;
  if v_status = 'pending_claim' and v_purchase.expires_at <= now() then
    v_status := 'expired';
  end if;

  if v_status = 'pending_claim' and v_program.id is not null then
    select * into v_campaign
      from public.loyalty_campaigns c
     where c.business_id = v_purchase.business_id
       and c.is_active
       and c.valid_from <= now()
       and (c.valid_until is null or c.valid_until > now())
       and v_purchase.amount_cop >= c.min_purchase_amount
     order by c.multiplier desc, c.bonus_points desc, c.created_at desc
     limit 1;

    v_points := floor(v_purchase.amount_cop::numeric / v_program.cop_per_point_unit)::integer;
    if v_campaign.id is not null then
      v_points := floor(v_points * greatest(coalesce(v_campaign.multiplier, 1), 1))::integer
                  + greatest(coalesce(v_campaign.bonus_points, 0), 0);
    end if;
    v_points := least(greatest(v_points, 0), 1000000);
  else
    v_points := v_purchase.points_awarded;
  end if;

  return jsonb_build_object(
    'purchase_id', v_purchase.id,
    'business_id', v_purchase.business_id,
    'business_name', coalesce(v_business.name, 'Negocio'),
    'business_slug', v_business.slug,
    'amount_cop', v_purchase.amount_cop,
    'points_preview', v_points,
    'status', v_status,
    'claimed', v_status = 'claimed',
    'expires_at', v_purchase.expires_at
  );
end;
$$;

revoke execute on function public.purchase_qr_preview(text) from public;
grant execute on function public.purchase_qr_preview(text) to anon;
grant execute on function public.purchase_qr_preview(text) to authenticated;
-- ---------------------------------------------------------------------
-- 5. El cliente confirma la compra y recibe los puntos
-- ---------------------------------------------------------------------
create or replace function public.purchase_qr_claim(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_purchase public.purchases;
  v_business public.businesses;
  v_membership_id uuid;
  v_account_id uuid;
  v_result jsonb;
  v_balance bigint;
  v_points integer := 0;
  v_now timestamptz := now();
  v_joined boolean := false;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  perform private.consume_rate_limit('purchase_qr_claim:' || v_uid::text, 20, 60);

  select * into v_purchase
    from public.purchases
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and business_id is not null
   for update;

  if not found then
    raise exception 'invalid_token';
  end if;

  if v_purchase.status = 'cancelled' then
    raise exception 'purchase_cancelled';
  end if;
  if v_purchase.status = 'claimed' then
    raise exception 'purchase_already_claimed';
  end if;
  if v_purchase.status = 'expired' or v_now >= v_purchase.expires_at then
    raise exception 'purchase_expired';
  end if;

  select * into v_business
    from public.businesses
   where id = v_purchase.business_id and is_active;

  if not found then raise exception 'business_not_found'; end if;

  -- Escanear el QR afilia al cliente al negocio si aún no lo estaba.
  insert into public.business_memberships (business_id, user_id, role, created_by)
  values (v_business.id, v_uid, 'cliente', v_uid)
  on conflict (business_id, user_id) do nothing
  returning id into v_membership_id;

  v_joined := v_membership_id is not null;

  insert into public.loyalty_point_accounts (business_id, customer_id)
  values (v_business.id, v_uid)
  on conflict (business_id, customer_id) do nothing;

  select id into v_account_id
    from public.loyalty_point_accounts
   where business_id = v_business.id and customer_id = v_uid;

  v_result := private.accrue_purchase_points(
    v_business.id,
    v_account_id,
    v_purchase.id,
    v_purchase.amount_cop,
    v_purchase.amount_cop,
    'purchase_qr:' || v_purchase.id::text,
    v_uid,
    'v1'
  );

  v_points := coalesce((v_result ->> 'points_earned')::integer, 0);
  v_balance := coalesce((v_result ->> 'balance')::bigint, 0);

  update public.purchases
     set status = 'claimed',
         claimed_by = v_uid,
         claimed_at = v_now,
         points_awarded = v_points
   where id = v_purchase.id;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    v_business.id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'purchase.qr_claimed',
    'purchase',
    v_purchase.id::text,
    jsonb_build_object(
      'amount_cop', v_purchase.amount_cop,
      'points_awarded', v_points,
      'balance', v_balance,
      'joined', v_joined
    )
  );

  if v_joined then
    insert into public.business_audit_logs (
      business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
    ) values (
      v_business.id,
      v_uid,
      (select email from public.profiles where id = v_uid),
      'membership.joined',
      'business_membership',
      v_membership_id::text,
      jsonb_build_object('slug', v_business.slug, 'role', 'cliente', 'source', 'purchase_qr')
    );
  end if;

  return jsonb_build_object(
    'purchase_id', v_purchase.id,
    'business_id', v_business.id,
    'business_name', v_business.name,
    'business_slug', v_business.slug,
    'amount_cop', v_purchase.amount_cop,
    'points_awarded', v_points,
    'balance', v_balance,
    'claimed_at', v_now,
    'duplicate', coalesce((v_result ->> 'duplicate')::boolean, false)
  );
end;
$$;

grant execute on function public.purchase_qr_claim(text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Historial y anulación de ventas del negocio
-- ---------------------------------------------------------------------
create or replace function public.business_purchases_list(
  p_business_id uuid,
  p_limit integer default 20,
  p_offset integer default 0,
  p_status public.purchase_status default null
)
returns table (
  id uuid,
  amount_cop integer,
  status public.purchase_status,
  points_awarded integer,
  created_at timestamptz,
  expires_at timestamptz,
  claimed_at timestamptz,
  customer_name text,
  customer_email text,
  registrar_name text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  -- Un QR vencido deja de poder reclamarse aunque nadie lo haya cancelado.
  update public.purchases p
     set status = 'expired'
   where p.business_id = p_business_id
     and p.status = 'pending_claim'
     and p.expires_at <= now();

  return query
    select
      p.id,
      p.amount_cop,
      p.status,
      p.points_awarded,
      p.created_at,
      p.expires_at,
      p.claimed_at,
      coalesce(nullif(btrim(customer.full_name), ''), customer.email) as customer_name,
      customer.email as customer_email,
      registrar.full_name as registrar_name,
      count(*) over () as total_count
    from public.purchases p
    left join public.profiles customer on customer.id = p.claimed_by
    left join public.profiles registrar on registrar.id = p.registrar_id
   where p.business_id = p_business_id
     and (p_status is null or p.status = p_status)
   order by p.created_at desc
   limit v_limit
   offset v_offset;
end;
$$;

grant execute on function public.business_purchases_list(
  uuid, integer, integer, public.purchase_status
) to authenticated;

create or replace function public.purchase_qr_cancel(
  p_business_id uuid,
  p_purchase_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_purchase public.purchases;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  if v_reason is null or length(v_reason) < 3 or length(v_reason) > 300 then
    raise exception 'invalid_reason';
  end if;

  select * into v_purchase
    from public.purchases
   where id = p_purchase_id and business_id = p_business_id
   for update;

  if not found then raise exception 'purchase_not_found'; end if;
  if v_purchase.status = 'claimed' then raise exception 'purchase_already_claimed'; end if;
  if v_purchase.status = 'cancelled' then raise exception 'purchase_already_cancelled'; end if;

  update public.purchases
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = v_uid,
         cancellation_reason = v_reason
   where id = p_purchase_id;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'purchase.qr_cancelled',
    'purchase',
    p_purchase_id::text,
    jsonb_build_object('reason', v_reason, 'amount_cop', v_purchase.amount_cop)
  );

  return jsonb_build_object(
    'purchase_id', p_purchase_id,
    'status', 'cancelled'
  );
end;
$$;

grant execute on function public.purchase_qr_cancel(uuid, uuid, text) to authenticated;

-- No se expone la lógica interna ni se permite al cliente saltarse la venta.
revoke execute on function public.purchase_qr_create(uuid, integer) from public;
revoke execute on function public.purchase_qr_claim(text) from public;
revoke execute on function public.business_purchases_list(
  uuid, integer, integer, public.purchase_status
) from public;
revoke execute on function public.purchase_qr_cancel(uuid, uuid, text) from public;
