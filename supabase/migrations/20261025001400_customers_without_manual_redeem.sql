-- =====================================================================
-- Loopoint F5 · Clientes sin canje manual
--
--   1. `staff_list_customers` añade el filtro `p_only_frequent` (aditivo).
--   2. `staff_get_customer` con negocio devuelve:
--      - compras con ítems contados (QR) y compras manuales del libro,
--      - canjes del negocio en modo lectura,
--      - nickname, frecuencia y última compra.
-- =====================================================================

drop function if exists public.staff_list_customers(
  text, integer, integer, text, text, uuid
);

create or replace function public.staff_list_customers(
  p_search text default '',
  p_limit integer default 20,
  p_offset integer default 0,
  p_sort text default 'created_at',
  p_direction text default 'desc',
  p_business_id uuid default null,
  p_only_frequent boolean default false
)
returns table (
  id uuid,
  full_name text,
  email text,
  points_balance bigint,
  purchase_count integer,
  total_spent bigint,
  created_at timestamptz,
  total_count bigint,
  nickname text,
  is_frequent boolean,
  is_frequent_active boolean,
  last_purchase_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_search text;
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_order text;
  v_dir text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  if p_business_id is null then
    if not public.is_staff() then raise exception 'forbidden'; end if;
  else
    perform public.require_business_role(p_business_id, array['admin', 'encargado']);
  end if;

  v_search := btrim(coalesce(p_search, ''));
  v_search := replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_');

  v_order := case lower(coalesce(p_sort, 'created_at'))
    when 'name' then 'p.full_name'
    when 'email' then 'p.email'
    when 'points' then 'points_balance'
    when 'purchases' then 'purchase_count'
    when 'total_spent' then 'total_spent'
    when 'created_at' then 'p.created_at'
    else 'p.created_at'
  end;
  v_dir := case when lower(coalesce(p_direction, 'desc')) = 'asc' then 'asc' else 'desc' end;

  return query execute format($query$
    select p.id,
           p.full_name,
           p.email,
           case
             when $4 is null then
               coalesce((select sum(l.points) from public.points_ledger l where l.customer_id = p.id), 0)::bigint
             else
               coalesce((select a.balance from public.loyalty_point_accounts a
                          where a.business_id = $4 and a.customer_id = p.id), 0)::bigint
           end as points_balance,
           case
             when $4 is null then
               (select count(*) from public.purchases pu where pu.claimed_by = p.id and pu.status = 'claimed')::integer
             else
               (select count(*) from public.loyalty_purchase_events e
                  join public.loyalty_point_accounts a on a.id = e.account_id
                 where e.business_id = $4 and a.customer_id = p.id)::integer
           end as purchase_count,
           case
             when $4 is null then
               coalesce((select sum(pu.amount_cop) from public.purchases pu where pu.claimed_by = p.id and pu.status = 'claimed'), 0)::bigint
             else
               coalesce((select sum(e.amount_cop) from public.loyalty_purchase_events e
                           join public.loyalty_point_accounts a on a.id = e.account_id
                          where e.business_id = $4 and a.customer_id = p.id), 0)::bigint
           end as total_spent,
           p.created_at,
           count(*) over () as total_count,
           p.nickname,
           coalesce((f.f ->> 'is_frequent')::boolean, false) as is_frequent,
           coalesce((f.f ->> 'is_frequent_active')::boolean, false) as is_frequent_active,
           (f.f ->> 'last_purchase_at')::timestamptz as last_purchase_at
      from public.profiles p
      left join lateral (
        select private.customer_frequency($4, p.id) as f
      ) f on true
     where exists (
             select 1 from public.user_roles r
              where r.user_id = p.id and r.role = 'customer'
           )
       and not exists (
             select 1 from public.user_roles r
              where r.user_id = p.id and r.role = 'admin'
           )
       and (
             $4 is null
             or exists (
               select 1 from public.business_memberships m
                where m.business_id = $4 and m.user_id = p.id and m.role = 'cliente'
             )
           )
       and (
             not coalesce($5, false)
             or coalesce((f.f ->> 'is_frequent')::boolean, false)
           )
       and (
             $1 = ''
             or p.full_name ilike '%%' || $1 || '%%'
             or p.email ilike '%%' || $1 || '%%'
             or coalesce(p.nickname, '') ilike '%%' || $1 || '%%'
           )
     order by %s %s, p.id
     limit $2 offset $3
  $query$, v_order, v_dir)
  using v_search, v_limit, v_offset, p_business_id, p_only_frequent;
end;
$$;

grant execute on function public.staff_list_customers(
  text, integer, integer, text, text, uuid, boolean
) to authenticated;
revoke execute on function public.staff_list_customers(
  text, integer, integer, text, text, uuid, boolean
) from public, anon;

create or replace function public.staff_get_customer(
  p_customer_id uuid,
  p_business_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
  v_frequency jsonb;
  v_balance bigint;
  v_purchase_count integer;
  v_total_spent bigint;
  v_purchases jsonb;
  v_movements jsonb;
  v_redemptions jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  if p_business_id is null then
    if not public.is_staff() then raise exception 'forbidden'; end if;
  else
    perform public.require_business_role(p_business_id, array['admin', 'encargado']);

    if not exists (
      select 1 from public.business_memberships m
       where m.business_id = p_business_id and m.user_id = p_customer_id
    ) then
      raise exception 'customer_not_found';
    end if;
  end if;

  if not exists (select 1 from public.profiles where id = p_customer_id) then
    raise exception 'customer_not_found';
  end if;

  v_frequency := private.customer_frequency(p_business_id, p_customer_id);

  if p_business_id is null then
    v_balance := coalesce(
      (select sum(l.points) from public.points_ledger l where l.customer_id = p_customer_id),
      0
    );
    v_purchase_count := (
      select count(*) from public.purchases pu
       where pu.claimed_by = p_customer_id and pu.status = 'claimed'
    );
    v_total_spent := coalesce(
      (select sum(pu.amount_cop) from public.purchases pu
        where pu.claimed_by = p_customer_id and pu.status = 'claimed'),
      0
    );

    select coalesce(jsonb_agg(to_jsonb(x) order by x.claimed_at desc), '[]'::jsonb)
      into v_purchases
      from (
        select pu.id, pu.amount_cop, pu.points_awarded, pu.claimed_at, pu.status,
               (select count(*)::integer from public.purchase_items pi
                 where pi.purchase_id = pu.id) as items_count,
               'qr'::text as source
          from public.purchases pu
         where pu.claimed_by = p_customer_id and pu.status = 'claimed'
         order by pu.claimed_at desc
         limit 50
      ) x;

    select coalesce(jsonb_agg(to_jsonb(y) order by y.created_at desc), '[]'::jsonb)
      into v_movements
      from (
        select l.id, l.movement_type, l.points, l.reason, l.created_at
          from public.points_ledger l
         where l.customer_id = p_customer_id
         order by l.created_at desc
         limit 50
      ) y;

    select coalesce(jsonb_agg(to_jsonb(z) order by z.created_at desc), '[]'::jsonb)
      into v_redemptions
      from (
        select r.id, r.reward_name, r.points_spent, r.code,
               r.status::text as status, r.created_at, r.delivered_at, r.cancelled_at
          from public.redemptions r
         where r.customer_id = p_customer_id
         order by r.created_at desc
         limit 50
      ) z;
  else
    v_balance := coalesce(
      (select a.balance from public.loyalty_point_accounts a
        where a.business_id = p_business_id and a.customer_id = p_customer_id),
      0
    );
    v_purchase_count := coalesce((v_frequency ->> 'purchase_count')::integer, 0);
    v_total_spent := coalesce((v_frequency ->> 'total_spent_cop')::bigint, 0);

    -- Compras con QR (detalle) y compras manuales registradas en el libro.
    select coalesce(jsonb_agg(to_jsonb(x) order by x.claimed_at desc), '[]'::jsonb)
      into v_purchases
      from (
        select *
          from (
            select pu.id,
                   pu.amount_cop,
                   pu.points_awarded,
                   pu.claimed_at,
                   'claimed'::public.purchase_status as status,
                   (select count(*)::integer from public.purchase_items pi
                     where pi.purchase_id = pu.id) as items_count,
                   'qr'::text as source
              from public.purchases pu
             where pu.business_id = p_business_id
               and pu.claimed_by = p_customer_id
               and pu.status = 'claimed'
            union all
            select e.id,
                   e.amount_cop,
                   e.points_earned,
                   e.created_at,
                   'claimed'::public.purchase_status,
                   0,
                   'manual'::text
              from public.loyalty_purchase_events e
              join public.loyalty_point_accounts a on a.id = e.account_id
             where e.business_id = p_business_id
               and a.customer_id = p_customer_id
               and e.purchase_id is null
          ) u
         order by u.claimed_at desc
         limit 50
      ) x;

    select coalesce(jsonb_agg(to_jsonb(y) order by y.created_at desc), '[]'::jsonb)
      into v_movements
      from (
        select t.id, t.movement_type, t.points, t.reason, t.created_at
          from public.loyalty_point_transactions t
          join public.loyalty_point_accounts a on a.id = t.account_id
         where a.customer_id = p_customer_id
           and t.business_id = p_business_id
         order by t.created_at desc
         limit 50
      ) y;

    select coalesce(jsonb_agg(to_jsonb(z) order by z.created_at desc), '[]'::jsonb)
      into v_redemptions
      from (
        select r.id,
               r.reward_name,
               r.points_spent,
               r.code,
               case r.status
                 when 'delivered' then 'redeemed'
                 when 'cancelled' then 'cancelled'
                 when 'expired' then 'cancelled'
                 else 'pending_delivery'
               end as status,
               r.created_at,
               r.delivered_at,
               r.cancelled_at
          from public.loyalty_redemptions r
          join public.loyalty_point_accounts a on a.id = r.account_id
         where r.business_id = p_business_id
           and a.customer_id = p_customer_id
         order by r.created_at desc
         limit 50
      ) z;
  end if;

  select jsonb_build_object(
    'profile', jsonb_build_object(
      'id', p.id,
      'full_name', p.full_name,
      'email', p.email,
      'nickname', p.nickname,
      'created_at', p.created_at
    ),
    'business_id', p_business_id,
    'nickname', p.nickname,
    'is_frequent', coalesce((v_frequency ->> 'is_frequent')::boolean, false),
    'is_frequent_active', coalesce((v_frequency ->> 'is_frequent_active')::boolean, false),
    'is_recovering', coalesce((v_frequency ->> 'is_recovering')::boolean, false),
    'last_purchase_at', v_frequency -> 'last_purchase_at',
    'points_balance', v_balance,
    'purchase_count', v_purchase_count,
    'total_spent', v_total_spent,
    'purchases', v_purchases,
    'movements', v_movements,
    'redemptions', v_redemptions
  )
  into v_result
  from public.profiles p
  where p.id = p_customer_id;

  return v_result;
end;
$$;

grant execute on function public.staff_get_customer(uuid, uuid) to authenticated;
revoke execute on function public.staff_get_customer(uuid, uuid) from public, anon;

do $$
begin
  if not exists (
    select 1 from pg_proc
     where proname = 'staff_list_customers'
       and pronamespace = 'public'::regnamespace
       and pg_get_function_identity_arguments(oid) like '%p_only_frequent boolean%'
  ) then
    raise exception 'staff_list_customers no acepta p_only_frequent';
  end if;
end
$$;
