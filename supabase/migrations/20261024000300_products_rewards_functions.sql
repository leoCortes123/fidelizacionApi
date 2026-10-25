-- =====================================================================
-- Productos de la carta y catálogo de recompensas por negocio
-- =====================================================================

-- ---------------------------------------------------------------------
-- Upsert producto (solo admin del negocio)
-- ---------------------------------------------------------------------
create or replace function public.product_upsert(
  p_business_id uuid,
  p_price_cop integer,
  p_name text default '',
  p_id uuid default null,
  p_description text default null,
  p_cost_cop integer default null,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_name text := btrim(coalesce(p_name, ''));
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception 'invalid_product_name';
  end if;
  if p_price_cop is null or p_price_cop <= 0 or p_price_cop > 100000000 then
    raise exception 'invalid_product_price';
  end if;
  if p_cost_cop is not null and p_cost_cop < 0 then
    raise exception 'invalid_product_cost';
  end if;

  if p_id is null then
    insert into public.products (
      business_id, name, description, price_cop, cost_cop, is_active
    ) values (
      p_business_id, v_name, btrim(coalesce(p_description, '')),
      p_price_cop, p_cost_cop, p_is_active
    )
    returning id into v_id;
  else
    update public.products
       set name = v_name,
           description = btrim(coalesce(p_description, '')),
           price_cop = p_price_cop,
           cost_cop = p_cost_cop,
           is_active = p_is_active,
           updated_at = now()
     where id = p_id and business_id = p_business_id
    returning id into v_id;
    if v_id is null then raise exception 'product_not_found'; end if;
  end if;

  return (select to_jsonb(r) from public.products r where r.id = v_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Listar productos del negocio (admin/encargado; cliente solo activos)
-- ---------------------------------------------------------------------
create or replace function public.products_list(
  p_business_id uuid,
  p_only_active boolean default true
)
returns table (
  id uuid,
  name text,
  description text,
  price_cop integer,
  cost_cop integer,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  return query
    select id, name, description, price_cop, cost_cop, is_active, created_at, updated_at
      from public.products
     where business_id = p_business_id
       and (not p_only_active or is_active)
     order by name;
end;
$$;

-- ---------------------------------------------------------------------
-- Upsert recompensa (solo admin del negocio)
-- Para producto gratuito se vincula a products y se copian precio y costo.
-- ---------------------------------------------------------------------
create or replace function public.loyalty_reward_upsert(
  p_business_id uuid,
  p_type public.loyalty_reward_type,
  p_name text,
  p_points_required integer,
  p_id uuid default null,
  p_product_id uuid default null,
  p_description text default '',
  p_min_purchase_amount integer default 0,
  p_max_discount_amount integer default null,
  p_discount_percentage numeric default null,
  p_valid_from timestamptz default null,
  p_valid_until timestamptz default null,
  p_max_redemptions_per_customer integer default null,
  p_max_redemptions_per_period integer default null,
  p_redemption_period_days integer default null,
  p_total_redemption_limit integer default null,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_price_cop integer;
  v_cost_cop integer;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  if length(btrim(coalesce(p_name, ''))) < 2 then
    raise exception 'invalid_reward_name';
  end if;
  if p_points_required <= 0 or p_points_required > 10000000 then
    raise exception 'invalid_reward_points';
  end if;
  if p_min_purchase_amount < 0 then
    raise exception 'invalid_min_purchase';
  end if;
  if p_discount_percentage is not null and (p_discount_percentage <= 0 or p_discount_percentage > 100) then
    raise exception 'invalid_discount_percentage';
  end if;
  if p_max_discount_amount is not null and p_max_discount_amount < 0 then
    raise exception 'invalid_max_discount';
  end if;
  if p_type = 'free_product' then
    if p_product_id is null then
      raise exception 'free_product_requires_product';
    end if;
    select price_cop, cost_cop into v_price_cop, v_cost_cop
      from public.products
     where id = p_product_id and business_id = p_business_id;
    if not found then
      raise exception 'product_not_found';
    end if;
  else
    v_price_cop := null;
    v_cost_cop := null;
  end if;

  if p_id is null then
    insert into public.loyalty_rewards (
      business_id, product_id, type, name, description, points_required,
      min_purchase_amount, max_discount_amount, discount_percentage,
      product_price_cop, product_cost_cop, valid_from, valid_until,
      max_redemptions_per_customer, max_redemptions_per_period,
      redemption_period_days, total_redemption_limit, is_active, created_by
    ) values (
      p_business_id, p_product_id, p_type, btrim(p_name),
      btrim(coalesce(p_description, '')), p_points_required,
      p_min_purchase_amount, p_max_discount_amount, p_discount_percentage,
      v_price_cop, v_cost_cop, p_valid_from, p_valid_until,
      p_max_redemptions_per_customer, p_max_redemptions_per_period,
      p_redemption_period_days, p_total_redemption_limit, p_is_active, v_uid
    )
    returning id into v_id;
  else
    update public.loyalty_rewards
       set product_id = p_product_id,
           type = p_type,
           name = btrim(p_name),
           description = btrim(coalesce(p_description, '')),
           points_required = p_points_required,
           min_purchase_amount = p_min_purchase_amount,
           max_discount_amount = p_max_discount_amount,
           discount_percentage = p_discount_percentage,
           product_price_cop = v_price_cop,
           product_cost_cop = v_cost_cop,
           valid_from = p_valid_from,
           valid_until = p_valid_until,
           max_redemptions_per_customer = p_max_redemptions_per_customer,
           max_redemptions_per_period = p_max_redemptions_per_period,
           redemption_period_days = p_redemption_period_days,
           total_redemption_limit = p_total_redemption_limit,
           is_active = p_is_active,
           updated_at = now()
     where id = p_id and business_id = p_business_id
    returning id into v_id;
    if v_id is null then raise exception 'reward_not_found'; end if;
  end if;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    case when p_id is null then 'reward.created' else 'reward.updated' end,
    'loyalty_reward',
    v_id::text,
    jsonb_build_object(
      'name', p_name, 'type', p_type, 'points_required', p_points_required,
      'product_id', p_product_id, 'is_active', p_is_active
    )
  );

  return (select to_jsonb(r) from public.loyalty_rewards r where r.id = v_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Listar recompensas del negocio
-- ---------------------------------------------------------------------
create or replace function public.loyalty_rewards_list(
  p_business_id uuid,
  p_only_active boolean default true
)
returns table (
  id uuid,
  product_id uuid,
  type public.loyalty_reward_type,
  name text,
  description text,
  points_required integer,
  min_purchase_amount integer,
  max_discount_amount integer,
  discount_percentage numeric,
  product_price_cop integer,
  product_cost_cop integer,
  is_active boolean,
  valid_from timestamptz,
  valid_until timestamptz,
  max_redemptions_per_customer integer,
  max_redemptions_per_period integer,
  redemption_period_days integer,
  total_redemption_limit integer,
  created_at timestamptz,
  updated_at timestamptz,
  times_redeemed bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  return query
    select r.id, r.product_id, r.type, r.name, r.description, r.points_required,
           r.min_purchase_amount, r.max_discount_amount, r.discount_percentage,
           r.product_price_cop, r.product_cost_cop, r.is_active,
           r.valid_from, r.valid_until, r.max_redemptions_per_customer,
           r.max_redemptions_per_period, r.redemption_period_days,
           r.total_redemption_limit, r.created_at, r.updated_at,
           coalesce((select count(*) from public.loyalty_redemptions d
                      where d.reward_id = r.id and d.status = 'delivered'), 0)::bigint
      from public.loyalty_rewards r
     where r.business_id = p_business_id
       and (not p_only_active or r.is_active)
     order by r.points_required asc, r.name asc;
end;
$$;

-- ---------------------------------------------------------------------
-- Recompensas disponibles para un cliente del negocio (saldo válido)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_rewards_available(
  p_business_id uuid,
  p_customer_id uuid
)
returns table (
  id uuid,
  type public.loyalty_reward_type,
  name text,
  description text,
  points_required integer,
  min_purchase_amount integer,
  max_discount_amount integer,
  discount_percentage numeric,
  product_price_cop integer,
  product_cost_cop integer,
  balance integer,
  remaining integer,
  can_redeem boolean,
  valid_from timestamptz,
  valid_until timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_balance integer := 0;
  v_now timestamptz := now();
  v_membership public.business_memberships;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  -- Solo el propio cliente consulta sus recompensas disponibles
  v_membership := public.business_current_membership(p_business_id);
  if v_membership.user_id <> v_uid and v_membership.role <> 'admin' then
    raise exception 'forbidden';
  end if;

  select coalesce(balance, 0) into v_balance
    from public.loyalty_point_accounts
   where business_id = p_business_id and customer_id = p_customer_id;

  return query
    select r.id, r.type, r.name, r.description, r.points_required,
           r.min_purchase_amount, r.max_discount_amount, r.discount_percentage,
           r.product_price_cop, r.product_cost_cop,
           v_balance,
           greatest(r.points_required - v_balance, 0),
           v_balance >= r.points_required
             and r.is_active
             and (r.valid_from is null or r.valid_from <= v_now)
             and (r.valid_until is null or r.valid_until > v_now),
           r.valid_from, r.valid_until
      from public.loyalty_rewards r
     where r.business_id = p_business_id
       and r.is_active
       and (r.valid_from is null or r.valid_from <= v_now)
       and (r.valid_until is null or r.valid_until > v_now)
     order by r.points_required asc, r.name asc;
end;
$$;
