-- Corrige ambigüedad en la variable/columna 'balance' en loyalty_rewards_available.
-- Al declarar RETURNS TABLE(..., balance integer, ...), PL/pgSQL define una variable de salida 'balance'.
-- La consulta select coalesce(balance, 0) into v_balance from public.loyalty_point_accounts
-- fallaba con 'column reference "balance" is ambiguous' (SQLSTATE 42702), provocando HTTP 400 en PostgREST.

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
  v_customer_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  v_membership := public.business_current_membership(p_business_id);

  -- Solo el admin puede consultar el saldo de otro cliente del negocio.
  v_customer_id := case
    when v_membership.role = 'admin' then p_customer_id
    else v_uid
  end;

  select coalesce(lpa.balance, 0) into v_balance
    from public.loyalty_point_accounts lpa
   where lpa.business_id = p_business_id and lpa.customer_id = v_customer_id;

  v_balance := coalesce(v_balance, 0);

  return query
    select r.id, r.type, r.name, r.description, r.points_required,
           r.min_purchase_amount, r.max_discount_amount, r.discount_percentage,
           r.product_price_cop,
           case when v_membership.role = 'admin' then r.product_cost_cop else null end,
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

revoke all on function public.loyalty_rewards_available(uuid, uuid) from public, anon;
grant execute on function public.loyalty_rewards_available(uuid, uuid) to authenticated;
