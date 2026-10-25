-- =====================================================================
-- Perfil económico del negocio y cálculo de presupuesto de recompensas
-- =====================================================================

-- ---------------------------------------------------------------------
-- Upsert datos económicos del negocio (solo admin)
-- Cada dato puede marcarse como confirmado, estimado o desconocido.
-- ---------------------------------------------------------------------
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

  insert into public.business_economic_profiles (
    business_id, daily_avg_sales, monthly_operation_days, daily_gain,
    gross_margin, avg_customers_per_day, max_monthly_reward_budget,
    data_status, updated_by
  ) values (
    p_business_id, p_daily_avg_sales, p_monthly_operation_days, p_daily_gain,
    p_gross_margin, p_avg_customers_per_day, p_max_monthly_reward_budget,
    p_data_status, v_uid
  )
  on conflict (business_id) do update
    set daily_avg_sales = coalesce(excluded.daily_avg_sales, business_economic_profiles.daily_avg_sales),
        monthly_operation_days = coalesce(excluded.monthly_operation_days, business_economic_profiles.monthly_operation_days),
        daily_gain = coalesce(excluded.daily_gain, business_economic_profiles.daily_gain),
        gross_margin = coalesce(excluded.gross_margin, business_economic_profiles.gross_margin),
        avg_customers_per_day = coalesce(excluded.avg_customers_per_day, business_economic_profiles.avg_customers_per_day),
        max_monthly_reward_budget = coalesce(excluded.max_monthly_reward_budget, business_economic_profiles.max_monthly_reward_budget),
        data_status = coalesce(excluded.data_status, business_economic_profiles.data_status),
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
    p_data_status
  );

  return jsonb_build_object(
    'business_id', p_business_id,
    'updated_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Panel económico del negocio
-- ---------------------------------------------------------------------
create or replace function public.business_dashboard_economic(
  p_business_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.business_economic_profiles;
  v_program public.loyalty_programs;
  v_monthly_sales bigint := 0;
  v_reference_budget bigint := 0;
  v_redeemed_cost bigint := 0;
  v_pending_cost bigint := 0;
  v_reserved_cost bigint := 0;
  v_max_budget integer;
  v_pct numeric;
  v_now timestamptz := now();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  select * into v_profile from public.business_economic_profiles where business_id = p_business_id;
  select * into v_program from public.loyalty_programs where business_id = p_business_id;

  -- Ventas mensuales estimadas = ventas diarias × días de operación mensuales
  if v_profile.daily_avg_sales is not null and v_profile.monthly_operation_days is not null then
    v_monthly_sales := v_profile.daily_avg_sales * v_profile.monthly_operation_days;
  end if;

  -- Presupuesto de referencia = ventas mensuales × tasa de presupuesto
  if v_monthly_sales > 0 and v_program.budget_rate is not null then
    v_reference_budget := floor(v_monthly_sales * v_program.budget_rate);
  end if;

  -- Costo de premios redimidos (estimación comercial basada en precios)
  select coalesce(sum(r.points_spent * coalesce(rw.product_price_cop, 0)), 0)::bigint into v_redeemed_cost
    from public.loyalty_redemptions r
    join public.loyalty_rewards rw on rw.id = r.reward_id
   where r.business_id = p_business_id
     and r.status = 'delivered';

  -- Costo de puntos pendientes (estimación)
  select coalesce(sum(r.points_spent * coalesce(rw.product_price_cop, 0)), 0)::bigint into v_pending_cost
    from public.loyalty_redemptions r
    join public.loyalty_rewards rw on rw.id = r.reward_id
   where r.business_id = p_business_id
     and r.status in ('pending', 'approved');

  -- Costo de premios reservados (mismo que pendientes para evitar doble conteo)
  v_reserved_cost := v_pending_cost;

  -- Presupuesto restante y porcentaje comprometido
  v_max_budget := coalesce(v_profile.max_monthly_reward_budget, v_reference_budget);
  v_pct := case
    when v_max_budget > 0 then round((v_redeemed_cost::numeric / v_max_budget) * 100, 2)
    else 0
  end;

  return jsonb_build_object(
    'business_id', p_business_id,
    'monthly_estimated_sales_cop', v_monthly_sales,
    'reference_budget_cop', v_reference_budget,
    'budget_rate', coalesce(v_program.budget_rate, 0),
    'redeemed_rewards_cost_cop', v_redeemed_cost,
    'pending_rewards_cost_cop', v_pending_cost,
    'reserved_rewards_cost_cop', v_reserved_cost,
    'remaining_budget_cop', greatest(v_max_budget - v_redeemed_cost - v_pending_cost, 0),
    'budget_committed_percent', v_pct,
    'max_monthly_reward_budget_cop', v_max_budget,
    'data_status', coalesce(v_profile.data_status, '{}'::jsonb),
    'estimated', v_profile.daily_avg_sales is null or v_profile.monthly_operation_days is null,
    'calculated_at', v_now
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Listar auditoría del negocio
-- ---------------------------------------------------------------------
create or replace function public.business_audit_log_list(
  p_business_id uuid,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  id uuid,
  actor_email text,
  operation text,
  entity_type text,
  entity_id text,
  metadata jsonb,
  created_at timestamptz
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
    select a.id, a.actor_email, a.operation, a.entity_type, a.entity_id, a.metadata, a.created_at
      from public.business_audit_logs a
     where a.business_id = p_business_id
     order by a.created_at desc
     limit v_limit offset v_offset;
end;
$$;
