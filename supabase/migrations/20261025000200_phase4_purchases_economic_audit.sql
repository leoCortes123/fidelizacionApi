-- =====================================================================
-- Fase 4 — Acumulación auditada, panel económico y auditoría paginada
--
-- Cambios:
--   1. `loyalty_purchase_events.idempotency_key`: evita duplicar el evento
--      de compra cuando la acumulación deja 0 puntos (sin movimiento).
--   2. `points_accrue_from_purchase`: idempotencia también por evento y
--      devuelve `purchase_event_id` para poder auditar/revertir la compra.
--   3. `loyalty_purchase_register`: registra la compra en la auditoría del
--      negocio y devuelve el id del evento.
--   4. `loyalty_purchase_revert`: reverso por evento con motivo, idempotente
--      y auditado (cierra la brecha de reversos sin `purchase_id` legacy).
--   5. `business_economic_profile_get` y semántica de formulario completo en
--      `business_economic_profile_upsert` (permite marcar datos como
--      desconocidos limpiando el valor).
--   6. `business_audit_log_page`: listado paginado con filtro por operación
--      y `total_count`.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Clave de idempotencia del evento de compra
-- ---------------------------------------------------------------------
alter table public.loyalty_purchase_events
  add column if not exists idempotency_key text;

create unique index if not exists loyalty_purchase_events_business_idempotency
  on public.loyalty_purchase_events (business_id, idempotency_key)
  where idempotency_key is not null;

comment on column public.loyalty_purchase_events.idempotency_key is
  'Clave idempotente de la acumulación. Permite detectar reintentos incluso cuando la compra generó 0 puntos.';

-- ---------------------------------------------------------------------
-- 2. Acumulación idempotente (misma firma que la versión vigente)
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
  v_uid uuid := auth.uid();
  v_program public.loyalty_programs;
  v_account public.loyalty_point_accounts;
  v_event public.loyalty_purchase_events;
  v_points integer;
  v_tx public.loyalty_point_transactions;
  v_balance bigint;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  if p_amount_cop is null or p_amount_cop <= 0 then
    raise exception 'invalid_amount';
  end if;
  if p_eligible_amount_cop is null or p_eligible_amount_cop < 0 or p_eligible_amount_cop > p_amount_cop then
    raise exception 'invalid_eligible_amount';
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9:_-]{8,120}$' then
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

  -- Evitar duplicar puntos al reprocesar una misma compra legacy.
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

  v_points := floor(p_eligible_amount_cop::numeric / v_program.cop_per_point_unit)::integer;
  v_points := least(v_points, 1000000);

  if v_points > 0 then
    perform public.loyalty_transaction_post(
      p_business_id, p_account_id, 'purchase_credit', v_points,
      'purchase', p_purchase_id,
      format('Compra %s COP elegibles %s COP (regla %s)',
             p_amount_cop, p_eligible_amount_cop, coalesce(p_rule_version, 'inicial')),
      p_idempotency_key, v_uid
    );
  end if;

  insert into public.loyalty_purchase_events (
    business_id, account_id, purchase_id, amount_cop,
    eligible_amount_cop, points_earned, rule_version, idempotency_key
  ) values (
    p_business_id, p_account_id, p_purchase_id, p_amount_cop,
    p_eligible_amount_cop, v_points, coalesce(p_rule_version, 'v1'),
    p_idempotency_key
  )
  returning * into v_event;

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  return jsonb_build_object(
    'points_earned', v_points,
    'balance', v_balance,
    'duplicate', false,
    'purchase_event_id', v_event.id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Registro de compra desde el panel: audita la operación
-- ---------------------------------------------------------------------
create or replace function public.loyalty_purchase_register(
  p_business_id uuid,
  p_customer_id uuid,
  p_amount_cop integer,
  p_eligible_amount_cop integer,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_account_id uuid;
  v_result jsonb;
  v_duplicate boolean;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  if p_customer_id is null then raise exception 'invalid_customer'; end if;
  if not exists (
    select 1 from public.business_memberships
     where business_id = p_business_id and user_id = p_customer_id
  ) then
    raise exception 'customer_not_member';
  end if;

  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,64}$' then
    raise exception 'invalid_idempotency_key';
  end if;

  insert into public.loyalty_point_accounts (business_id, customer_id)
  values (p_business_id, p_customer_id)
  on conflict (business_id, customer_id) do nothing;

  select id into v_account_id
    from public.loyalty_point_accounts
   where business_id = p_business_id and customer_id = p_customer_id;

  v_result := public.points_accrue_from_purchase(
    p_business_id,
    v_account_id,
    null,
    p_amount_cop,
    p_eligible_amount_cop,
    'purchase:' || p_business_id::text || ':' || p_idempotency_key,
    v_uid,
    'v1'
  );

  v_duplicate := coalesce((v_result->>'duplicate')::boolean, false);

  if not v_duplicate then
    insert into public.business_audit_logs (
      business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
    ) values (
      p_business_id,
      v_uid,
      (select email from public.profiles where id = v_uid),
      'purchase.registered',
      'loyalty_purchase_event',
      coalesce(v_result->>'purchase_event_id', ''),
      jsonb_build_object(
        'customer_id', p_customer_id,
        'amount_cop', p_amount_cop,
        'eligible_amount_cop', p_eligible_amount_cop,
        'points_earned', coalesce((v_result->>'points_earned')::integer, 0)
      )
    );
  end if;

  return v_result || jsonb_build_object('account_id', v_account_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Reverso de una compra registrada desde el panel (solo admin)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_purchase_revert(
  p_business_id uuid,
  p_event_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.loyalty_purchase_events;
  v_balance bigint;
  v_key text;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  select * into v_event
    from public.loyalty_purchase_events
   where id = p_event_id and business_id = p_business_id
   for update;

  if not found then
    raise exception 'purchase_event_not_found';
  end if;

  if length(v_reason) > 300 then
    raise exception 'invalid_reason';
  end if;
  if v_reason = '' then
    v_reason := 'Reverso de compra';
  end if;

  v_key := 'purchase-event:' || p_event_id::text || ':reverse';

  if exists (
    select 1 from public.loyalty_point_transactions
     where idempotency_key = v_key
  ) then
    select coalesce(sum(points), 0) into v_balance
      from public.loyalty_point_transactions
     where account_id = v_event.account_id;
    return jsonb_build_object(
      'points_reversed', 0,
      'balance', v_balance,
      'duplicate', true,
      'message', 'La compra ya fue revertida.'
    );
  end if;

  if v_event.points_earned > 0 then
    perform public.loyalty_transaction_post(
      p_business_id, v_event.account_id, 'admin_adjustment', -v_event.points_earned,
      'purchase_event', v_event.id,
      v_reason,
      v_key, v_uid
    );
  end if;

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = v_event.account_id;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'purchase.reverted',
    'loyalty_purchase_event',
    p_event_id::text,
    jsonb_build_object(
      'points_reversed', v_event.points_earned,
      'reason', v_reason,
      'amount_cop', v_event.amount_cop
    )
  );

  return jsonb_build_object(
    'points_reversed', v_event.points_earned,
    'balance', v_balance,
    'duplicate', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Perfil económico: lectura y upsert con semántica de formulario
--    (null limpia el dato: así se marca un dato como "desconocido").
-- ---------------------------------------------------------------------
create or replace function public.business_economic_profile_get(
  p_business_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.business_economic_profiles;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  select * into v_profile
    from public.business_economic_profiles
   where business_id = p_business_id;

  if not found then
    return null;
  end if;

  return to_jsonb(v_profile);
end;
$$;

create or replace function public.business_economic_profile_upsert(
  p_business_id uuid,
  p_daily_avg_sales integer default null,
  p_monthly_operation_days integer default null,
  p_daily_gain integer default null,
  p_gross_margin numeric default null,
  p_avg_customers_per_day integer default null,
  p_max_monthly_reward_budget integer default null,
  p_data_status jsonb default '{}'::jsonb
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
  perform public.require_business_role(p_business_id, array['admin']);

  if p_daily_avg_sales is not null and p_daily_avg_sales < 0 then
    raise exception 'invalid_sales';
  end if;
  if p_monthly_operation_days is not null and (p_monthly_operation_days < 1 or p_monthly_operation_days > 31) then
    raise exception 'invalid_operation_days';
  end if;
  if p_daily_gain is not null and p_daily_gain < 0 then
    raise exception 'invalid_daily_gain';
  end if;
  if p_gross_margin is not null and (p_gross_margin < 0 or p_gross_margin > 100) then
    raise exception 'invalid_gross_margin';
  end if;
  if p_avg_customers_per_day is not null and p_avg_customers_per_day < 0 then
    raise exception 'invalid_avg_customers';
  end if;
  if p_max_monthly_reward_budget is not null and p_max_monthly_reward_budget < 0 then
    raise exception 'invalid_budget';
  end if;
  if p_data_status is not null and jsonb_typeof(p_data_status) <> 'object' then
    raise exception 'invalid_data_status';
  end if;

  insert into public.business_economic_profiles (
    business_id, daily_avg_sales, monthly_operation_days, daily_gain,
    gross_margin, avg_customers_per_day, max_monthly_reward_budget,
    data_status, updated_by
  ) values (
    p_business_id, p_daily_avg_sales, p_monthly_operation_days, p_daily_gain,
    p_gross_margin, p_avg_customers_per_day, p_max_monthly_reward_budget,
    coalesce(p_data_status, '{}'::jsonb), v_uid
  )
  on conflict (business_id) do update
    set daily_avg_sales = excluded.daily_avg_sales,
        monthly_operation_days = excluded.monthly_operation_days,
        daily_gain = excluded.daily_gain,
        gross_margin = excluded.gross_margin,
        avg_customers_per_day = excluded.avg_customers_per_day,
        max_monthly_reward_budget = excluded.max_monthly_reward_budget,
        data_status = excluded.data_status,
        updated_by = v_uid,
        updated_at = now();

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'economic_profile.updated',
    'business_economic_profile',
    p_business_id::text,
    coalesce(p_data_status, '{}'::jsonb)
  );

  return jsonb_build_object(
    'business_id', p_business_id,
    'updated_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Auditoría paginada con filtro por operación
-- ---------------------------------------------------------------------
create or replace function public.business_audit_log_page(
  p_business_id uuid,
  p_operation text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  actor_email text,
  operation text,
  entity_type text,
  entity_id text,
  metadata jsonb,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_operation text := btrim(coalesce(p_operation, ''));
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  v_operation := replace(replace(replace(v_operation, '\', '\\'), '%', '\%'), '_', '\_');

  return query
    select a.id,
           a.actor_email,
           a.operation,
           a.entity_type,
           a.entity_id,
           a.metadata,
           a.created_at,
           count(*) over () as total_count
      from public.business_audit_logs a
     where a.business_id = p_business_id
       and (v_operation = '' or a.operation ilike '%' || v_operation || '%')
     order by a.created_at desc
     limit v_limit offset v_offset;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Permisos
-- ---------------------------------------------------------------------
grant execute on function public.business_economic_profile_get(uuid) to authenticated;
grant execute on function public.business_economic_profile_upsert(
  uuid, integer, integer, integer, numeric, integer, integer, jsonb
) to authenticated;
grant execute on function public.business_audit_log_page(
  uuid, text, integer, integer
) to authenticated;
grant execute on function public.loyalty_purchase_register(
  uuid, uuid, integer, integer, text
) to authenticated;
grant execute on function public.loyalty_purchase_revert(
  uuid, uuid, text
) to authenticated;
grant execute on function public.points_accrue_from_purchase(
  uuid, uuid, uuid, integer, integer, text, uuid, text
) to authenticated;

-- ---------------------------------------------------------------------
-- 8. Comprobaciones rápidas
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'loyalty_purchase_events'
       and column_name = 'idempotency_key'
  ) then
    raise exception 'falta loyalty_purchase_events.idempotency_key';
  end if;

  if not exists (
    select 1 from pg_proc
     where proname = 'business_audit_log_page'
       and pronamespace = 'public'::regnamespace
  ) then
    raise exception 'falta business_audit_log_page';
  end if;
end;
$$;
