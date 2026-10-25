-- =====================================================================
-- Redenciones mediante QR y tokens
-- =====================================================================

-- ---------------------------------------------------------------------
-- Cliente solicita una redención: valida saldo, reserva puntos, genera QR
-- ---------------------------------------------------------------------
create or replace function public.reward_request_redemption(
  p_business_id uuid,
  p_reward_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_reward public.loyalty_rewards;
  v_account public.loyalty_point_accounts;
  v_membership public.business_memberships;
  v_existing public.loyalty_redemptions;
  v_redemption_id uuid;
  v_code text;
  v_token text;
  v_token_hash text;
  v_program public.loyalty_programs;
  v_expires_at timestamptz;
  v_balance bigint;
  v_now timestamptz := now();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,64}$' then
    raise exception 'invalid_idempotency_key';
  end if;

  v_membership := public.business_current_membership(p_business_id);
  if v_membership.user_id <> v_uid then
    raise exception 'forbidden';
  end if;

  select * into v_account
    from public.loyalty_point_accounts
   where business_id = p_business_id and customer_id = v_uid;

  if not found then
    raise exception 'account_not_found';
  end if;

  -- Idempotencia: devolver la misma solicitud sin volver a reservar.
  select * into v_existing
    from public.loyalty_redemptions
   where account_id = v_account.id and idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'redemption_id', v_existing.id,
      'reward_name', v_existing.reward_name,
      'points_spent', v_existing.points_spent,
      'status', v_existing.status,
      'code', v_existing.code,
      'created_at', v_existing.created_at,
      'duplicate', true
    );
  end if;

  select * into v_reward
    from public.loyalty_rewards
   where id = p_reward_id and business_id = p_business_id
   for share;

  if not found or not v_reward.is_active then
    raise exception 'reward_unavailable';
  end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found or not v_program.is_active then
    raise exception 'program_not_active';
  end if;

  -- Vigencia de la recompensa.
  if v_reward.valid_from is not null and v_reward.valid_from > v_now then
    raise exception 'reward_not_yet_valid';
  end if;
  if v_reward.valid_until is not null and v_reward.valid_until <= v_now then
    raise exception 'reward_expired';
  end if;

  -- Límites por cliente y periodo.
  if v_reward.max_redemptions_per_customer is not null then
    select count(*) into v_balance
      from public.loyalty_redemptions r
      join public.loyalty_point_accounts a on a.id = r.account_id
     where a.business_id = p_business_id
       and a.customer_id = v_uid
       and r.reward_id = p_reward_id
       and r.status in ('pending', 'approved', 'delivered');
    if v_balance >= v_reward.max_redemptions_per_customer then
      raise exception 'reward_customer_limit_reached';
    end if;
  end if;

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = v_account.id;

  if v_balance < v_reward.points_required then
    raise exception 'insufficient_points'
      using detail = format('Tienes %s puntos y se requieren %s.', v_balance, v_reward.points_required);
  end if;

  -- Reservar puntos (débito pendiente).
  perform public.loyalty_transaction_post(
    p_business_id, v_account.id, 'redemption_debit', -v_reward.points_required,
    'redemption', null,
    format('Reserva para recompensa %s', v_reward.name),
    'redemption:' || gen_random_uuid()::text || ':reserve', v_uid
  );

  loop
    v_code := 'TP' || upper(encode(extensions.gen_random_bytes(6), 'hex'));
    exit when not exists (select 1 from public.loyalty_redemptions where code = v_code);
  end loop;

  insert into public.loyalty_redemptions (
    business_id, account_id, reward_id, reward_name, reward_type,
    points_spent, code, status, idempotency_key, created_by, created_at
  ) values (
    p_business_id, v_account.id, v_reward.id, v_reward.name, v_reward.type,
    v_reward.points_required, v_code, 'pending', p_idempotency_key, v_uid, v_now
  )
  returning id into v_redemption_id;

  -- Generar token QR aleatorio vinculado al negocio y la solicitud.
  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  v_expires_at := v_now + make_interval(hours => coalesce(v_program.qr_expiry_hours, 24));

  insert into public.loyalty_redemption_tokens (
    business_id, redemption_id, token_hash, expires_at
  ) values (
    p_business_id, v_redemption_id, v_token_hash, v_expires_at
  );

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.requested',
    'loyalty_redemption',
    v_redemption_id::text,
    jsonb_build_object(
      'reward_id', v_reward.id,
      'reward_name', v_reward.name,
      'points_spent', v_reward.points_required,
      'expires_at', v_expires_at
    )
  );

  return jsonb_build_object(
    'redemption_id', v_redemption_id,
    'reward_name', v_reward.name,
    'points_spent', v_reward.points_required,
    'code', v_code,
    'status', 'pending',
    'token', v_token,
    'expires_at', v_expires_at,
    'duplicate', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Validar un token QR (encargado escanea)
-- ---------------------------------------------------------------------
create or replace function public.redemption_token_validate(
  p_business_id uuid,
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_token_hash text;
  v_token public.loyalty_redemption_tokens;
  v_redemption public.loyalty_redemptions;
  v_membership public.business_memberships;
  v_now timestamptz := now();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  v_token_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');

  select * into v_token
    from public.loyalty_redemption_tokens
   where token_hash = v_token_hash
   for update;

  if not found then
    raise exception 'invalid_token';
  end if;

  -- Aislamiento: el token debe pertenecer al negocio del encargado.
  if v_token.business_id <> p_business_id then
    raise exception 'forbidden';
  end if;

  v_membership := public.business_current_membership(p_business_id);
  if v_membership.role <> 'admin' and v_membership.role <> 'encargado' then
    raise exception 'forbidden';
  end if;
  if v_membership.role = 'encargado' and not v_membership.can_approve_redemptions then
    raise exception 'forbidden';
  end if;

  select * into v_redemption
    from public.loyalty_redemptions
   where id = v_token.redemption_id
   for update;

  if not found then
    raise exception 'redemption_not_found';
  end if;

  if v_redemption.business_id <> p_business_id then
    raise exception 'forbidden';
  end if;

  if v_redemption.status <> 'pending' then
    raise exception 'redemption_not_pending';
  end if;

  if v_token.consumed_at is not null then
    raise exception 'token_already_consumed';
  end if;

  if v_token.expires_at <= v_now then
    raise exception 'token_expired';
  end if;

  return jsonb_build_object(
    'redemption_id', v_redemption.id,
    'reward_name', v_redemption.reward_name,
    'reward_type', v_redemption.reward_type,
    'points_spent', v_redemption.points_spent,
    'status', v_redemption.status,
    'customer_id', v_redemption.account_id,
    'expires_at', v_token.expires_at,
    'can_approve', true
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Encargado aprueba una redención (solo si tiene permiso)
-- ---------------------------------------------------------------------
create or replace function public.redemption_approve(
  p_business_id uuid,
  p_redemption_id uuid,
  p_approve boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_redemption public.loyalty_redemptions;
  v_token public.loyalty_redemption_tokens;
  v_membership public.business_memberships;
  v_now timestamptz := now();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_redemption
    from public.loyalty_redemptions
   where id = p_redemption_id
   for update;

  if not found then
    raise exception 'redemption_not_found';
  end if;

  if v_redemption.business_id <> p_business_id then
    raise exception 'forbidden';
  end if;

  v_membership := public.business_current_membership(p_business_id);
  if v_membership.role <> 'admin' and v_membership.role <> 'encargado' then
    raise exception 'forbidden';
  end if;
  if v_membership.role = 'encargado' and not v_membership.can_approve_redemptions then
    raise exception 'forbidden';
  end if;

  if v_redemption.status <> 'pending' then
    raise exception 'redemption_not_pending';
  end if;

  if p_approve then
    select * into v_token
      from public.loyalty_redemption_tokens
     where redemption_id = p_redemption_id
     for update;

    if not found then
      raise exception 'token_not_found';
    end if;

    if v_token.consumed_at is not null then
      raise exception 'token_already_consumed';
    end if;

    if v_token.expires_at <= v_now then
      raise exception 'token_expired';
    end if;

    update public.loyalty_redemptions
       set status = 'approved',
           approved_by = v_uid,
           approved_at = v_now
     where id = p_redemption_id;

    update public.loyalty_redemption_tokens
       set consumed_at = v_now,
           consumed_by = v_uid
     where redemption_id = p_redemption_id;

    insert into public.business_audit_logs (
      business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
    ) values (
      p_business_id,
      v_uid,
      (select email from public.profiles where id = v_uid),
      'redemption.approved',
      'loyalty_redemption',
      p_redemption_id::text,
      jsonb_build_object('reward_name', v_redemption.reward_name, 'points_spent', v_redemption.points_spent)
    );

    return jsonb_build_object(
      'redemption_id', p_redemption_id,
      'status', 'approved',
      'approved_by', v_uid,
      'approved_at', v_now
    );
  else
    -- Rechazar/cancelar: liberar puntos reservados.
    update public.loyalty_redemptions
       set status = 'cancelled',
           cancelled_at = v_now,
           cancellation_reason = 'Rechazado por el encargado'
     where id = p_redemption_id;

    perform public.loyalty_transaction_post(
      p_business_id, v_redemption.account_id, 'redemption_refund', v_redemption.points_spent,
      'redemption', p_redemption_id,
      'Redención rechazada y puntos liberados',
      'redemption:' || p_redemption_id::text || ':refund', v_uid
    );

    return jsonb_build_object(
      'redemption_id', p_redemption_id,
      'status', 'cancelled',
      'points_refunded', v_redemption.points_spent
    );
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Confirmar entrega y consumir puntos (admin o encargado con permiso)
-- ---------------------------------------------------------------------
create or replace function public.redemption_deliver(
  p_business_id uuid,
  p_redemption_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_redemption public.loyalty_redemptions;
  v_membership public.business_memberships;
  v_now timestamptz := now();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_redemption
    from public.loyalty_redemptions
   where id = p_redemption_id
   for update;

  if not found then
    raise exception 'redemption_not_found';
  end if;

  if v_redemption.business_id <> p_business_id then
    raise exception 'forbidden';
  end if;

  v_membership := public.business_current_membership(p_business_id);
  if v_membership.role <> 'admin' and v_membership.role <> 'encargado' then
    raise exception 'forbidden';
  end if;
  if v_membership.role = 'encargado' and not v_membership.can_approve_redemptions then
    raise exception 'forbidden';
  end if;

  if v_redemption.status <> 'approved' then
    raise exception 'redemption_not_approved';
  end if;

  update public.loyalty_redemptions
     set status = 'delivered',
         delivered_at = v_now
   where id = p_redemption_id;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.delivered',
    'loyalty_redemption',
    p_redemption_id::text,
    jsonb_build_object('reward_name', v_redemption.reward_name, 'points_spent', v_redemption.points_spent)
  );

  return jsonb_build_object(
    'redemption_id', p_redemption_id,
    'status', 'delivered',
    'delivered_at', v_now
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Cancelar redención pendiente (liberar puntos)
-- ---------------------------------------------------------------------
create or replace function public.redemption_cancel(
  p_business_id uuid,
  p_redemption_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_redemption public.loyalty_redemptions;
  v_membership public.business_memberships;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if v_reason is null or length(v_reason) > 300 then raise exception 'invalid_reason'; end if;

  select * into v_redemption
    from public.loyalty_redemptions
   where id = p_redemption_id
   for update;

  if not found then
    raise exception 'redemption_not_found';
  end if;

  if v_redemption.business_id <> p_business_id then
    raise exception 'forbidden';
  end if;

  v_membership := public.business_current_membership(p_business_id);
  if v_membership.role <> 'admin' then
    raise exception 'forbidden';
  end if;

  if v_redemption.status <> 'pending' then
    raise exception 'redemption_not_pending';
  end if;

  update public.loyalty_redemptions
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = v_uid,
         cancellation_reason = v_reason
   where id = p_redemption_id;

  perform public.loyalty_transaction_post(
    p_business_id, v_redemption.account_id, 'redemption_refund', v_redemption.points_spent,
    'redemption', p_redemption_id,
    v_reason,
    'redemption:' || p_redemption_id::text || ':cancel_refund', v_uid
  );

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.cancelled',
    'loyalty_redemption',
    p_redemption_id::text,
    jsonb_build_object('reason', v_reason, 'points_refunded', v_redemption.points_spent)
  );

  return jsonb_build_object(
    'redemption_id', p_redemption_id,
    'status', 'cancelled',
    'points_refunded', v_redemption.points_spent
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Listar redenciones del negocio (admin/encargado)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_redemptions_list(
  p_business_id uuid,
  p_status public.redemption_request_status default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  id uuid,
  reward_name text,
  reward_type public.loyalty_reward_type,
  points_spent integer,
  code text,
  status public.redemption_request_status,
  created_at timestamptz,
  approved_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  customer_id uuid,
  customer_email text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  return query
    select r.id, r.reward_name, r.reward_type, r.points_spent, r.code, r.status,
           r.created_at, r.approved_at, r.delivered_at, r.cancelled_at,
           a.customer_id, p.email
      from public.loyalty_redemptions r
      join public.loyalty_point_accounts a on a.id = r.account_id
      join public.profiles p on p.id = a.customer_id
     where r.business_id = p_business_id
       and (p_status is null or r.status = p_status)
     order by r.created_at desc
     limit v_limit offset v_offset;
end;
$$;
