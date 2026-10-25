-- =====================================================================
-- Cuentas de puntos, libro de movimientos, acumulación y reversos
-- =====================================================================

-- ---------------------------------------------------------------------
-- Asegurar cuenta de puntos para un cliente en un negocio (una única)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_account_ensure(
  p_business_id uuid,
  p_customer_id uuid
)
returns public.loyalty_point_accounts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account public.loyalty_point_accounts;
begin
  select * into v_account
    from public.loyalty_point_accounts
   where business_id = p_business_id
     and customer_id = p_customer_id;

  if not found then
    insert into public.loyalty_point_accounts (business_id, customer_id, balance)
    values (p_business_id, p_customer_id, 0)
    returning * into v_account;
  end if;

  return v_account;
end;
$$;

-- ---------------------------------------------------------------------
-- Registrar movimiento en el libro y actualizar saldo (atómico)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_transaction_post(
  p_business_id uuid,
  p_account_id uuid,
  p_movement_type public.point_movement_type,
  p_points integer,
  p_idempotency_key text,
  p_created_by uuid,
  p_reference_type text default null,
  p_reference_id uuid default null,
  p_reason text default null
)
returns public.loyalty_point_transactions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account public.loyalty_point_accounts;
  v_new_balance bigint;
  v_tx public.loyalty_point_transactions;
begin
  -- Idempotencia: si ya existe el movimiento, devolverlo sin duplicar.
  select * into v_tx
    from public.loyalty_point_transactions
   where idempotency_key = p_idempotency_key
   for update;

  if found then
    return v_tx;
  end if;

  select * into v_account
    from public.loyalty_point_accounts
   where id = p_account_id and business_id = p_business_id
   for update;

  if not found then
    raise exception 'account_not_found';
  end if;

  insert into public.loyalty_point_transactions (
    business_id, account_id, movement_type, points,
    reference_type, reference_id, reason, idempotency_key, created_by
  ) values (
    p_business_id, p_account_id, p_movement_type, p_points,
    p_reference_type, p_reference_id, p_reason, p_idempotency_key, p_created_by
  )
  returning * into v_tx;

  select coalesce(sum(points), 0) into v_new_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  if v_new_balance < 0 then
    raise exception 'negative_points_balance';
  end if;

  update public.loyalty_point_accounts
     set balance = v_new_balance,
         updated_at = now()
   where id = p_account_id;

  return v_tx;
end;
$$;

-- ---------------------------------------------------------------------
-- Acumular puntos de una compra (idempotente, evita duplicados)
-- Fórmula: floor(importe_elegible / importe_por_punto)
-- ---------------------------------------------------------------------
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
  v_program public.loyalty_programs;
  v_points integer;
  v_tx public.loyalty_point_transactions;
  v_balance bigint;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found or not v_program.is_active then
    raise exception 'program_not_active';
  end if;

  -- Evitar duplicar puntos al reprocesar una misma compra.
  if p_purchase_id is not null then
    if exists (
      select 1 from public.loyalty_purchase_events where purchase_id = p_purchase_id
    ) then
      return jsonb_build_object(
        'points_earned', 0,
        'duplicate', true,
        'message', 'La compra ya fue procesada.'
      );
    end if;
  end if;

  v_points := floor(p_eligible_amount_cop::numeric / v_program.cop_per_point_unit)::integer;
  v_points := least(v_points, 1000000); -- seguridad: límite razonable por evento

  if v_points > 0 then
    select * into v_tx
      from public.loyalty_transaction_post(
        p_business_id, p_account_id, 'purchase_credit', v_points,
        'purchase', p_purchase_id,
        format('Compra %s COP elegibles %s COP (regla %s)',
               p_amount_cop, p_eligible_amount_cop, coalesce(p_rule_version, 'inicial')),
        p_idempotency_key, p_created_by
      );
  end if;

  insert into public.loyalty_purchase_events (
    business_id, account_id, purchase_id, amount_cop,
    eligible_amount_cop, points_earned, rule_version
  ) values (
    p_business_id, p_account_id, p_purchase_id, p_amount_cop,
    p_eligible_amount_cop, v_points, p_rule_version
  );

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  return jsonb_build_object(
    'points_earned', v_points,
    'balance', v_balance,
    'duplicate', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Reversar puntos de una compra anulada/devuelta
-- ---------------------------------------------------------------------
create or replace function public.points_reverse_purchase(
  p_business_id uuid,
  p_account_id uuid,
  p_purchase_id uuid,
  p_reason text,
  p_created_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event public.loyalty_purchase_events;
  v_tx public.loyalty_point_transactions;
  v_balance bigint;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  select * into v_event
    from public.loyalty_purchase_events
   where purchase_id = p_purchase_id and business_id = p_business_id
   for update;

  if not found then
    raise exception 'purchase_event_not_found';
  end if;

  if v_event.points_earned <= 0 then
    return jsonb_build_object('points_reversed', 0, 'balance', v_event.points_earned);
  end if;

  -- Idempotencia: evitar doble devolución.
  if exists (
    select 1 from public.loyalty_point_transactions
    where account_id = p_account_id
      and movement_type = 'redemption_refund'
      and reference_type = 'purchase'
      and reference_id = p_purchase_id
  ) then
    return jsonb_build_object(
      'points_reversed', 0,
      'duplicate', true,
      'message', 'La compra ya fue revertida.'
    );
  end if;

  select * into v_tx
    from public.loyalty_transaction_post(
      p_business_id, p_account_id, 'redemption_refund', -v_event.points_earned,
      'purchase', p_purchase_id,
      p_reason,
      'purchase:' || p_purchase_id::text || ':reverse', p_created_by
    );

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  return jsonb_build_object(
    'points_reversed', v_event.points_earned,
    'balance', v_balance,
    'duplicate', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Bonos (primera compra, recurrencia, referidos) configurables
-- ---------------------------------------------------------------------
create or replace function public.points_grant_bonus(
  p_business_id uuid,
  p_account_id uuid,
  p_bonus_type text,
  p_points integer,
  p_reason text,
  p_idempotency_key text,
  p_created_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_program public.loyalty_programs;
  v_points integer := greatest(p_points, 0);
  v_tx public.loyalty_point_transactions;
  v_balance bigint;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if v_points <= 0 then
    return jsonb_build_object('points_granted', 0, 'skipped', true);
  end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found or not v_program.is_active then
    raise exception 'program_not_active';
  end if;

  select * into v_tx
    from public.loyalty_transaction_post(
      p_business_id, p_account_id, 'bonus_credit', v_points,
      'bonus', null, p_reason, p_idempotency_key, p_created_by
    );

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  return jsonb_build_object(
    'points_granted', v_points,
    'balance', v_balance,
    'skipped', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Saldo de una cuenta (cliente propio o staff del negocio)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_account_balance(
  p_business_id uuid,
  p_customer_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_balance integer := 0;
  v_membership public.business_memberships;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  v_membership := public.business_current_membership(p_business_id);
  if v_membership.user_id <> v_uid and v_membership.role <> 'admin' and v_membership.role <> 'encargado' then
    raise exception 'forbidden';
  end if;

  select coalesce(balance, 0) into v_balance
    from public.loyalty_point_accounts
   where business_id = p_business_id and customer_id = p_customer_id;

  return jsonb_build_object(
    'business_id', p_business_id,
    'customer_id', p_customer_id,
    'balance', v_balance
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Movimientos de puntos de una cuenta (historial)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_account_transactions(
  p_business_id uuid,
  p_customer_id uuid,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  movement_type public.point_movement_type,
  points integer,
  reference_type text,
  reference_id uuid,
  reason text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_membership public.business_memberships;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  v_membership := public.business_current_membership(p_business_id);
  if v_membership.user_id <> v_uid and v_membership.role <> 'admin' and v_membership.role <> 'encargado' then
    raise exception 'forbidden';
  end if;

  return query
    select t.id, t.movement_type, t.points, t.reference_type, t.reference_id, t.reason, t.created_at
      from public.loyalty_point_transactions t
      join public.loyalty_point_accounts a on a.id = t.account_id
     where a.business_id = p_business_id
       and a.customer_id = p_customer_id
     order by t.created_at desc, t.id desc
     limit v_limit offset v_offset;
end;
$$;
