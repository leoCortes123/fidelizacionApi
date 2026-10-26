-- =====================================================================
-- Loopoint F7 · M4 — Portal del cliente multi-negocio
--
-- Cambios aditivos:
--   1. `customer_businesses_summary()`: una fila por negocio al que
--      pertenece el usuario autenticado, con saldo, recompensas listas,
--      solicitudes pendientes, última compra y frecuencia.
--   2. `loyalty_my_redemptions` incluye `business_slug` y `business_logo_url`
--      para que la lista global de canjes identifique al negocio.
--
-- Reglas:
--   * Solo membresías del usuario autenticado (`auth.uid()`).
--   * El cliente nunca envía `business_id` para leer su resumen: el
--     servidor deriva cada fila de `business_memberships`.
--   * Los saldos y la frecuencia se calculan por negocio; no se mezclan.
--   * `staff_list_customers` / `staff_get_customer` ya devuelven nickname,
--     frecuencia y última compra por negocio desde F2/F5, por lo que no
--     se recrean aquí.
--
-- No se edita ninguna migración ya aplicada. Campañas: sin cambios.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Resumen multi-negocio del cliente
-- ---------------------------------------------------------------------
create or replace function public.customer_businesses_summary()
returns table (
  business_id uuid,
  name text,
  slug text,
  logo_url text,
  role public.business_role,
  loyalty_active boolean,
  balance integer,
  ready_rewards integer,
  pending_redemptions integer,
  last_purchase_at timestamptz,
  is_frequent boolean,
  is_frequent_active boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  return query
    select b.id,
           b.name,
           b.slug,
           b.logo_url,
           m.role,
           coalesce(lp.is_active, false) as loyalty_active,
           coalesce(acc.balance, 0) as balance,
           (
             select count(*)::integer
               from public.loyalty_rewards r
              where r.business_id = b.id
                and r.is_active
                and (r.valid_from is null or r.valid_from <= now())
                and (r.valid_until is null or r.valid_until > now())
                and r.points_required <= coalesce(acc.balance, 0)
           ) as ready_rewards,
           (
             select count(*)::integer
               from public.loyalty_redemptions red
               join public.loyalty_point_accounts ra on ra.id = red.account_id
              where red.business_id = b.id
                and ra.customer_id = v_uid
                and red.status in ('pending', 'approved')
           ) as pending_redemptions,
           freq.last_purchase_at,
           coalesce(freq.is_frequent, false) as is_frequent,
           coalesce(freq.is_frequent_active, false) as is_frequent_active
      from public.business_memberships m
      join public.businesses b on b.id = m.business_id
      left join public.loyalty_programs lp on lp.business_id = b.id
      left join lateral (
        select a.balance
          from public.loyalty_point_accounts a
         where a.business_id = b.id
           and a.customer_id = v_uid
      ) acc on true
      left join lateral (
        select (f ->> 'last_purchase_at')::timestamptz as last_purchase_at,
               (f ->> 'is_frequent')::boolean as is_frequent,
               (f ->> 'is_frequent_active')::boolean as is_frequent_active
          from (select private.customer_frequency(b.id, v_uid) as f) s
      ) freq on true
     where m.user_id = v_uid
     order by freq.last_purchase_at desc nulls last, b.name asc;
end;
$$;

grant execute on function public.customer_businesses_summary() to authenticated;
revoke execute on function public.customer_businesses_summary() from public, anon;

comment on function public.customer_businesses_summary() is
  'Resumen por negocio del cliente autenticado: saldo, recompensas listas, solicitudes pendientes, última compra y frecuencia.';

-- ---------------------------------------------------------------------
-- 2. Canjes del cliente con identidad del negocio
--    Se recrea porque cambia el tipo de retorno (columnas nuevas).
-- ---------------------------------------------------------------------
drop function if exists public.loyalty_my_redemptions(integer, integer);

create or replace function public.loyalty_my_redemptions(
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  id uuid,
  business_id uuid,
  business_name text,
  business_slug text,
  business_logo_url text,
  reward_name text,
  reward_type public.loyalty_reward_type,
  points_spent integer,
  code text,
  status public.redemption_request_status,
  created_at timestamptz,
  approved_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  return query
    select r.id, r.business_id, b.name, b.slug, b.logo_url,
           r.reward_name, r.reward_type, r.points_spent, r.code, r.status,
           r.created_at, r.approved_at, r.delivered_at, r.cancelled_at
      from public.loyalty_redemptions r
      join public.loyalty_point_accounts a on a.id = r.account_id
      join public.businesses b on b.id = r.business_id
     where a.customer_id = v_uid
     order by r.created_at desc
     limit v_limit offset v_offset;
end;
$$;

grant execute on function public.loyalty_my_redemptions(integer, integer) to authenticated;
revoke execute on function public.loyalty_my_redemptions(integer, integer) from public, anon;

comment on function public.loyalty_my_redemptions(integer, integer) is
  'Canjes del cliente autenticado en todos sus negocios, con nombre, slug y logo del negocio.';

-- ---------------------------------------------------------------------
-- 3. Índices de apoyo
-- ---------------------------------------------------------------------
create index if not exists loyalty_redemptions_customer_status_idx
  on public.loyalty_redemptions (business_id, status)
  include (account_id);

create index if not exists loyalty_point_accounts_customer_business_idx
  on public.loyalty_point_accounts (customer_id, business_id)
  include (balance);

-- ---------------------------------------------------------------------
-- 4. Comprobaciones
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'customer_businesses_summary'
  ) then
    raise exception 'customer_businesses_summary no existe';
  end if;

  if not exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name = 'businesses'
       and column_name = 'logo_url'
  ) then
    raise exception 'businesses.logo_url no existe';
  end if;

  if not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'loyalty_my_redemptions'
       and pg_get_function_result(p.oid) like '%business_slug%'
  ) then
    raise exception 'loyalty_my_redemptions no devuelve business_slug';
  end if;
end
$$;
