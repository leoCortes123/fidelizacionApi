-- =====================================================================
-- Fase 7 — Beneficio configurable con importe
--
-- La migración 20261025000600 limpiaba `max_discount_amount` para todo lo
-- que no fuera descuento fijo o porcentual, incluido `configurable_benefit`.
-- La UI permite definir un importe para ese tipo, así que se conserva.
-- =====================================================================

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
  v_discount_percentage numeric := p_discount_percentage;
  v_max_discount_amount integer := p_max_discount_amount;
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
  if p_valid_from is not null and p_valid_until is not null and p_valid_until <= p_valid_from then
    raise exception 'invalid_reward_validity';
  end if;
  if p_max_redemptions_per_period is not null then
    if p_max_redemptions_per_period < 1 then
      raise exception 'invalid_redemption_limit';
    end if;
    if p_redemption_period_days is null
       or p_redemption_period_days < 1
       or p_redemption_period_days > 3650 then
      raise exception 'invalid_redemption_period';
    end if;
  end if;
  if p_max_redemptions_per_customer is not null and p_max_redemptions_per_customer < 1 then
    raise exception 'invalid_redemption_limit';
  end if;
  if p_total_redemption_limit is not null and p_total_redemption_limit < 1 then
    raise exception 'invalid_redemption_limit';
  end if;

  -- Solo los descuentos porcentuales exigen porcentaje; el beneficio
  -- configurable conserva su importe si el admin lo define.
  if p_type = 'percentage_discount' then
    if p_discount_percentage is null or p_discount_percentage <= 0 or p_discount_percentage > 100 then
      raise exception 'invalid_discount_percentage';
    end if;
    v_max_discount_amount := p_max_discount_amount;
  elsif p_type = 'fixed_discount' then
    if p_max_discount_amount is null or p_max_discount_amount <= 0 then
      raise exception 'invalid_max_discount';
    end if;
    v_discount_percentage := null;
  elsif p_type = 'configurable_benefit' then
    v_discount_percentage := null;
  else
    v_discount_percentage := null;
    v_max_discount_amount := null;
  end if;

  if v_max_discount_amount is not null and v_max_discount_amount < 0 then
    raise exception 'invalid_max_discount';
  end if;
  -- Un descuento no puede superar el mínimo de compra que lo habilita;
  -- si no hay mínimo, tampoco hay tope que comparar.
  if v_max_discount_amount is not null
     and p_min_purchase_amount > 0
     and v_max_discount_amount > p_min_purchase_amount then
    raise exception 'discount_exceeds_min_purchase';
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
      p_min_purchase_amount, v_max_discount_amount, v_discount_percentage,
      v_price_cop, v_cost_cop, p_valid_from, p_valid_until,
      p_max_redemptions_per_customer, p_max_redemptions_per_period,
      case when p_max_redemptions_per_period is null then null else p_redemption_period_days end,
      p_total_redemption_limit, p_is_active, v_uid
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
           max_discount_amount = v_max_discount_amount,
           discount_percentage = v_discount_percentage,
           product_price_cop = v_price_cop,
           product_cost_cop = v_cost_cop,
           valid_from = p_valid_from,
           valid_until = p_valid_until,
           max_redemptions_per_customer = p_max_redemptions_per_customer,
           max_redemptions_per_period = p_max_redemptions_per_period,
           redemption_period_days = case
             when p_max_redemptions_per_period is null then null
             else p_redemption_period_days
           end,
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

-- Permisos (la firma no cambia; se conservan los grants de la migración previa).
revoke all on function public.loyalty_reward_upsert(
  uuid, public.loyalty_reward_type, text, integer, uuid, uuid, text, integer,
  integer, numeric, timestamptz, timestamptz, integer, integer, integer, integer, boolean
) from public;
grant execute on function public.loyalty_reward_upsert(
  uuid, public.loyalty_reward_type, text, integer, uuid, uuid, text, integer,
  integer, numeric, timestamptz, timestamptz, integer, integer, integer, integer, boolean
) to authenticated;
