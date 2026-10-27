-- =====================================================================
-- Loopoint F4 · M6 — Métricas reales del Inicio y actividad reciente
--
-- `business_dashboard_summary` agrega loopoints, solicitudes, clientes
-- frecuentes, ventas del día/mes, QR pendientes y presupuesto comprometido.
-- `business_recent_activity` normaliza compras y canjes recientes.
-- =====================================================================

create or replace function public.business_dashboard_summary(p_business_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_business public.businesses;
  v_today_start timestamptz;
  v_month_start timestamptz;
  v_points_outstanding bigint := 0;
  v_points_issued bigint := 0;
  v_points_redeemed bigint := 0;
  v_pending integer := 0;
  v_approved integer := 0;
  v_frequent integer := 0;
  v_active integer := 0;
  v_customers integer := 0;
  v_sales_today bigint := 0;
  v_sales_month bigint := 0;
  v_purchases_today integer := 0;
  v_purchases_month integer := 0;
  v_pending_qr integer := 0;
  v_budget numeric := 0;
  v_last_activity timestamptz;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  select * into v_business from public.businesses where id = p_business_id;
  if not found then raise exception 'business_not_found'; end if;

  v_today_start := date_trunc('day', now() at time zone v_business.timezone)
    at time zone v_business.timezone;
  v_month_start := date_trunc('month', now() at time zone v_business.timezone)
    at time zone v_business.timezone;

  select
    coalesce(sum(t.points), 0),
    coalesce(sum(t.points) filter (where t.points > 0), 0),
    coalesce(-sum(t.points) filter (
      where t.movement_type = 'redemption_debit' and t.points < 0
    ), 0)
    into v_points_outstanding, v_points_issued, v_points_redeemed
    from public.loyalty_point_transactions t
   where t.business_id = p_business_id;

  select count(*) into v_pending
    from public.loyalty_redemptions r
   where r.business_id = p_business_id and r.status = 'pending';

  select count(*) into v_approved
    from public.loyalty_redemptions r
   where r.business_id = p_business_id and r.status = 'approved';

  select count(*) into v_customers
    from public.business_memberships m
   where m.business_id = p_business_id and m.role = 'cliente';

  select count(*) into v_frequent
    from public.business_memberships m
   where m.business_id = p_business_id
     and m.role = 'cliente'
     and coalesce((private.customer_frequency(p_business_id, m.user_id) ->> 'is_frequent')::boolean, false);

  select count(*) into v_active
    from public.business_memberships m
   where m.business_id = p_business_id
     and m.role = 'cliente'
     and coalesce((private.customer_frequency(p_business_id, m.user_id) ->> 'is_frequent_active')::boolean, false);

  select
    coalesce(sum(e.amount_cop) filter (where e.created_at >= v_today_start), 0),
    coalesce(sum(e.amount_cop) filter (where e.created_at >= v_month_start), 0),
    count(*) filter (where e.created_at >= v_today_start),
    count(*) filter (where e.created_at >= v_month_start)
    into v_sales_today, v_sales_month, v_purchases_today, v_purchases_month
    from public.loyalty_purchase_events e
   where e.business_id = p_business_id
     and not exists (
       select 1 from public.loyalty_point_transactions t
        where t.reference_type = 'purchase_event'
          and t.reference_id = e.id
          and t.movement_type = 'admin_adjustment'
          and t.points < 0
     );

  select count(*) into v_pending_qr
    from public.purchases p
   where p.business_id = p_business_id
     and p.status = 'pending_claim'
     and p.expires_at > now();

  v_budget := coalesce(
    (public.business_dashboard_economic(p_business_id) ->> 'budget_committed_percent')::numeric,
    0
  );

  select greatest(
    (select max(e.created_at) from public.loyalty_purchase_events e where e.business_id = p_business_id),
    (select max(r.created_at) from public.loyalty_redemptions r where r.business_id = p_business_id),
    (select max(p.created_at) from public.purchases p where p.business_id = p_business_id)
  ) into v_last_activity;

  return jsonb_build_object(
    'business_id', p_business_id,
    'points_outstanding', v_points_outstanding,
    'points_issued_total', v_points_issued,
    'points_redeemed_total', v_points_redeemed,
    'pending_redemptions', v_pending,
    'approved_pending_delivery', v_approved,
    'frequent_customers', v_frequent,
    'active_customers', v_active,
    'customers_total', v_customers,
    'sales_today_cop', v_sales_today,
    'sales_month_cop', v_sales_month,
    'purchases_today', v_purchases_today,
    'purchases_month', v_purchases_month,
    'pending_qr_count', v_pending_qr,
    'budget_committed_percent', v_budget,
    'last_activity_at', v_last_activity,
    'calculated_at', now()
  );
end;
$$;

grant execute on function public.business_dashboard_summary(uuid) to authenticated;
revoke execute on function public.business_dashboard_summary(uuid) from public, anon;

create or replace function public.business_recent_activity(
  p_business_id uuid,
  p_limit integer default 10
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_activity jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', y.id,
           'kind', y.kind,
           'title', y.title,
           'detail', y.detail,
           'points', y.points,
           'amount_cop', y.amount_cop,
           'status', y.status,
           'created_at', y.created_at
         ) order by y.created_at desc), '[]'::jsonb)
    into v_activity
    from (
      select *
        from (
          select
            e.id,
            'purchase'::text as kind,
            'Compra registrada'::text as title,
            coalesce(pr.full_name, pr.nickname, 'Cliente') as detail,
            e.points_earned as points,
            e.amount_cop,
            null::text as status,
            e.created_at
            from public.loyalty_purchase_events e
            join public.loyalty_point_accounts a on a.id = e.account_id
            left join public.profiles pr on pr.id = a.customer_id
           where e.business_id = p_business_id
          union all
          select
            r.id,
            'redemption'::text,
            r.reward_name,
            coalesce(pr.full_name, pr.nickname, 'Cliente'),
            -r.points_spent,
            null::integer,
            r.status::text,
            r.created_at
            from public.loyalty_redemptions r
            join public.loyalty_point_accounts a on a.id = r.account_id
            left join public.profiles pr on pr.id = a.customer_id
           where r.business_id = p_business_id
        ) u
       order by u.created_at desc
       limit v_limit
    ) y;

  return v_activity;
end;
$$;

grant execute on function public.business_recent_activity(uuid, integer) to authenticated;
revoke execute on function public.business_recent_activity(uuid, integer) from public, anon;

-- Índices de apoyo para las métricas.
create index if not exists loyalty_purchase_events_business_created_idx
  on public.loyalty_purchase_events (business_id, created_at desc);

create index if not exists loyalty_redemptions_business_status_created_idx
  on public.loyalty_redemptions (business_id, status, created_at desc);

create index if not exists business_memberships_business_role_user_idx
  on public.business_memberships (business_id, role, user_id);

do $$
begin
  if not exists (
    select 1 from pg_proc
     where proname = 'business_dashboard_summary'
       and pronamespace = 'public'::regnamespace
  ) then
    raise exception 'falta business_dashboard_summary';
  end if;

  if not exists (
    select 1 from pg_proc
     where proname = 'business_recent_activity'
       and pronamespace = 'public'::regnamespace
  ) then
    raise exception 'falta business_recent_activity';
  end if;
end
$$;
