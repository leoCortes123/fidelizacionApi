-- =====================================================================
-- Fase 6 — Vencimiento de puntos, campañas y snapshots de presupuesto
--
--   1. Lotes de puntos: `loyalty_point_transactions.expires_at` y
--      `points_expire_due(business_id)` con consumo FIFO, sin saldo negativo,
--      idempotente y auditado.
--   2. Campañas: tabla `loyalty_campaigns`, CRUD auditado y aplicación en la
--      acumulación de compras (multiplicador + bono, solo dentro de vigencia).
--   3. Snapshots mensuales de presupuesto: tabla
--      `loyalty_budget_snapshots` y RPC de creación/listado reproducible.
--   4. Jobs diarios/mensuales con pg_cron cuando la extensión está disponible.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Lotes de puntos: fecha de vencimiento por movimiento
-- ---------------------------------------------------------------------
alter table public.loyalty_point_transactions
  add column if not exists expires_at timestamptz;

comment on column public.loyalty_point_transactions.expires_at is
  'Vencimiento del lote. Solo aplica a movimientos positivos; null = no vence.';

-- Los créditos históricos heredan el vencimiento del programa del negocio.
update public.loyalty_point_transactions t
   set expires_at = t.created_at + make_interval(days => p.points_expiry_days)
  from public.loyalty_programs p
 where p.business_id = t.business_id
   and t.points > 0
   and t.expires_at is null
   and p.points_expiry_days is not null;

create index if not exists loyalty_point_transactions_expiry_idx
  on public.loyalty_point_transactions (business_id, expires_at)
  where points > 0 and expires_at is not null;

-- ---------------------------------------------------------------------
-- 2. Movimiento atómico: asigna vencimiento a los lotes positivos
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
  v_expiry_days integer;
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

  select points_expiry_days into v_expiry_days
    from public.loyalty_programs
   where business_id = p_business_id;

  insert into public.loyalty_point_transactions (
    business_id, account_id, movement_type, points,
    reference_type, reference_id, reason, idempotency_key, created_by,
    expires_at
  ) values (
    p_business_id, p_account_id, p_movement_type, p_points,
    p_reference_type, p_reference_id, p_reason, p_idempotency_key, p_created_by,
    case
      when p_points > 0 and v_expiry_days is not null
        then now() + make_interval(days => v_expiry_days)
      else null
    end
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
-- 3. Campañas (tabla; el CRUD va más abajo)
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_campaigns (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null,
  description text not null default '',
  multiplier numeric(5,2) not null default 2,
  bonus_points integer not null default 0,
  min_purchase_amount integer not null default 0,
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  is_active boolean not null default true,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint loyalty_campaigns_name_length check (length(btrim(name)) between 2 and 120),
  constraint loyalty_campaigns_multiplier check (multiplier >= 1 and multiplier <= 10),
  constraint loyalty_campaigns_bonus check (bonus_points >= 0 and bonus_points <= 1000000),
  constraint loyalty_campaigns_min_purchase check (min_purchase_amount >= 0),
  constraint loyalty_campaigns_validity check (valid_until is null or valid_until > valid_from)
);

create index if not exists loyalty_campaigns_business_idx
  on public.loyalty_campaigns (business_id, created_at desc);
create index if not exists loyalty_campaigns_current_idx
  on public.loyalty_campaigns (business_id, is_active, valid_from, valid_until);

drop trigger if exists loyalty_campaigns_touch_updated_at on public.loyalty_campaigns;
create trigger loyalty_campaigns_touch_updated_at
  before update on public.loyalty_campaigns
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------
-- 4. Acumulación con campañas vigentes
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
  v_campaign public.loyalty_campaigns;
  v_account public.loyalty_point_accounts;
  v_event public.loyalty_purchase_events;
  v_base_points integer;
  v_points integer;
  v_tx public.loyalty_point_transactions;
  v_balance bigint;
  v_rule text;
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

  v_base_points := floor(p_eligible_amount_cop::numeric / v_program.cop_per_point_unit)::integer;

  -- Campaña vigente con mayor beneficio (solo si cumple la compra mínima).
  select * into v_campaign
    from public.loyalty_campaigns c
   where c.business_id = p_business_id
     and c.is_active
     and c.valid_from <= now()
     and (c.valid_until is null or c.valid_until > now())
     and p_eligible_amount_cop >= c.min_purchase_amount
   order by c.multiplier desc, c.bonus_points desc, c.created_at desc
   limit 1;

  if found then
    v_points := floor(v_base_points * greatest(coalesce(v_campaign.multiplier, 1), 1))::integer
                + greatest(coalesce(v_campaign.bonus_points, 0), 0);
  else
    v_points := v_base_points;
  end if;

  v_points := least(greatest(v_points, 0), 1000000);

  v_rule := coalesce(p_rule_version, 'v1');
  if v_campaign.id is not null then
    v_rule := v_rule || '+campaign:' || v_campaign.id::text;
  end if;

  if v_points > 0 then
    perform public.loyalty_transaction_post(
      p_business_id, p_account_id, 'purchase_credit', v_points,
      'purchase', p_purchase_id,
      format('Compra %s COP elegibles %s COP (regla %s%s)',
             p_amount_cop, p_eligible_amount_cop, v_rule,
             case when v_campaign.id is not null
                  then format(' · %s x%s +%s', v_campaign.name, v_campaign.multiplier, v_campaign.bonus_points)
                  else '' end),
      p_idempotency_key, v_uid
    );
  end if;

  insert into public.loyalty_purchase_events (
    business_id, account_id, purchase_id, amount_cop,
    eligible_amount_cop, points_earned, rule_version, idempotency_key
  ) values (
    p_business_id, p_account_id, p_purchase_id, p_amount_cop,
    p_eligible_amount_cop, v_points, v_rule, p_idempotency_key
  )
  returning * into v_event;

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  return jsonb_build_object(
    'points_earned', v_points,
    'balance', v_balance,
    'duplicate', false,
    'purchase_event_id', v_event.id,
    'base_points', v_base_points,
    'campaign_id', v_campaign.id,
    'campaign_name', v_campaign.name,
    'multiplier', coalesce(v_campaign.multiplier, 1),
    'bonus_points', coalesce(v_campaign.bonus_points, 0)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Vencimiento FIFO por negocio
-- ---------------------------------------------------------------------
create or replace function public.points_expire_due(p_business_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_lot record;
  v_balance integer;
  v_amount integer;
  v_lots integer := 0;
  v_points integer := 0;
  v_accounts integer := 0;
  v_last_account uuid;
  v_key text;
begin
  if v_uid is not null then
    perform public.require_business_role(p_business_id, array['admin']);
  end if;

  for v_lot in
    with credits as (
      select t.id,
             t.account_id,
             t.points,
             t.expires_at,
             t.created_at,
             coalesce(
               sum(t.points) over (
                 partition by t.account_id
                 order by t.created_at, t.id
                 rows between unbounded preceding and 1 preceding
               ), 0
             ) as credits_before
        from public.loyalty_point_transactions t
       where t.business_id = p_business_id
         and t.points > 0
    ),
    debits as (
      select t.account_id, sum(-t.points)::bigint as total_debits
        from public.loyalty_point_transactions t
       where t.business_id = p_business_id
         and t.points < 0
       group by t.account_id
    )
    select c.id,
           c.account_id,
           greatest(
             c.points - least(
               greatest(coalesce(d.total_debits, 0) - c.credits_before, 0),
               c.points
             ),
             0
           )::integer as remaining
      from credits c
      left join debits d on d.account_id = c.account_id
     where c.expires_at is not null
       and c.expires_at <= now()
     order by c.account_id, c.created_at, c.id
  loop
    if v_lot.remaining <= 0 then
      continue;
    end if;

    select balance into v_balance
      from public.loyalty_point_accounts
     where id = v_lot.account_id
     for update;

    if v_balance is null or v_balance <= 0 then
      continue;
    end if;

    v_key := 'expiry:' || v_lot.id::text;

    if exists (
      select 1 from public.loyalty_point_transactions
       where idempotency_key = v_key
    ) then
      continue;
    end if;

    v_amount := least(v_lot.remaining, v_balance);

    perform public.loyalty_transaction_post(
      p_business_id, v_lot.account_id, 'expiry_debit', -v_amount,
      'points_lot', v_lot.id,
      format('Vencimiento del lote %s', v_lot.id),
      v_key, v_uid
    );

    if v_lot.account_id is distinct from v_last_account then
      v_accounts := v_accounts + 1;
      v_last_account := v_lot.account_id;
    end if;
    v_lots := v_lots + 1;
    v_points := v_points + v_amount;
  end loop;

  if v_lots > 0 then
    insert into public.business_audit_logs (
      business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
    ) values (
      p_business_id,
      v_uid,
      (select email from public.profiles where id = v_uid),
      'points.expired',
      'loyalty_point_transactions',
      null,
      jsonb_build_object(
        'lots_expired', v_lots,
        'accounts_affected', v_accounts,
        'points_expired', v_points
      )
    );
  end if;

  return jsonb_build_object(
    'lots_expired', v_lots,
    'accounts_affected', v_accounts,
    'points_expired', v_points
  );
end;
$$;

create or replace function public.points_expire_all_due()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_business record;
  v_result jsonb;
  v_lots integer := 0;
  v_points integer := 0;
begin
  if auth.uid() is not null then
    raise exception 'forbidden';
  end if;

  for v_business in
    select id from public.businesses where is_active order by id
  loop
    v_result := public.points_expire_due(v_business.id);
    v_lots := v_lots + coalesce((v_result->>'lots_expired')::integer, 0);
    v_points := v_points + coalesce((v_result->>'points_expired')::integer, 0);
  end loop;

  return jsonb_build_object('lots_expired', v_lots, 'points_expired', v_points);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. CRUD de campañas
-- ---------------------------------------------------------------------
create or replace function public.loyalty_campaign_upsert(
  p_business_id uuid,
  p_name text,
  p_multiplier numeric default 2,
  p_bonus_points integer default 0,
  p_min_purchase_amount integer default 0,
  p_valid_from timestamptz default null,
  p_valid_until timestamptz default null,
  p_is_active boolean default true,
  p_description text default '',
  p_id uuid default null
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
  v_from timestamptz := coalesce(p_valid_from, now());
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception 'invalid_campaign_name';
  end if;
  if p_multiplier is null or p_multiplier < 1 or p_multiplier > 10 then
    raise exception 'invalid_campaign_multiplier';
  end if;
  if p_bonus_points is null or p_bonus_points < 0 or p_bonus_points > 1000000 then
    raise exception 'invalid_campaign_bonus';
  end if;
  if p_min_purchase_amount is null or p_min_purchase_amount < 0 then
    raise exception 'invalid_campaign_min_purchase';
  end if;
  if p_valid_until is not null and p_valid_until <= v_from then
    raise exception 'invalid_campaign_validity';
  end if;
  if length(coalesce(p_description, '')) > 500 then
    raise exception 'invalid_campaign_description';
  end if;

  if p_id is null then
    insert into public.loyalty_campaigns (
      business_id, name, description, multiplier, bonus_points,
      min_purchase_amount, valid_from, valid_until, is_active, created_by
    ) values (
      p_business_id, v_name, btrim(coalesce(p_description, '')),
      p_multiplier, p_bonus_points, p_min_purchase_amount,
      v_from, p_valid_until, coalesce(p_is_active, true), v_uid
    )
    returning id into v_id;
  else
    update public.loyalty_campaigns
       set name = v_name,
           description = btrim(coalesce(p_description, '')),
           multiplier = p_multiplier,
           bonus_points = p_bonus_points,
           min_purchase_amount = p_min_purchase_amount,
           valid_from = v_from,
           valid_until = p_valid_until,
           is_active = coalesce(p_is_active, true),
           updated_at = now()
     where id = p_id and business_id = p_business_id
    returning id into v_id;

    if v_id is null then raise exception 'campaign_not_found'; end if;
  end if;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    case when p_id is null then 'campaign.created' else 'campaign.updated' end,
    'loyalty_campaign',
    v_id::text,
    jsonb_build_object(
      'name', v_name,
      'multiplier', p_multiplier,
      'bonus_points', p_bonus_points,
      'valid_from', v_from,
      'valid_until', p_valid_until,
      'is_active', coalesce(p_is_active, true)
    )
  );

  return (select to_jsonb(c) from public.loyalty_campaigns c where c.id = v_id);
end;
$$;

create or replace function public.loyalty_campaign_list(
  p_business_id uuid,
  p_only_active boolean default false
)
returns table (
  id uuid,
  name text,
  description text,
  multiplier numeric,
  bonus_points integer,
  min_purchase_amount integer,
  valid_from timestamptz,
  valid_until timestamptz,
  is_active boolean,
  is_current boolean,
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
    select c.id, c.name, c.description, c.multiplier, c.bonus_points,
           c.min_purchase_amount, c.valid_from, c.valid_until, c.is_active,
           c.is_active
             and c.valid_from <= now()
             and (c.valid_until is null or c.valid_until > now()) as is_current,
           c.created_at, c.updated_at
      from public.loyalty_campaigns c
     where c.business_id = p_business_id
       and (not p_only_active or c.is_active)
     order by c.is_active desc, c.created_at desc;
end;
$$;

create or replace function public.loyalty_campaign_delete(
  p_business_id uuid,
  p_campaign_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_campaign public.loyalty_campaigns;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  delete from public.loyalty_campaigns
   where id = p_campaign_id and business_id = p_business_id
  returning * into v_campaign;

  if v_campaign.id is null then
    raise exception 'campaign_not_found';
  end if;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'campaign.deleted',
    'loyalty_campaign',
    p_campaign_id::text,
    jsonb_build_object('name', v_campaign.name)
  );

  return jsonb_build_object('campaign_id', p_campaign_id, 'deleted', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Snapshots mensuales de presupuesto
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_budget_snapshots (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  period_start date not null,
  period_end date not null,
  monthly_sales_cop bigint not null default 0,
  budget_rate numeric(5,4) not null default 0,
  reference_budget_cop bigint not null default 0,
  max_budget_cop bigint not null default 0,
  redeemed_cost_cop bigint not null default 0,
  pending_cost_cop bigint not null default 0,
  points_issued integer not null default 0,
  points_redeemed integer not null default 0,
  data jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint loyalty_budget_snapshots_period check (period_end >= period_start),
  constraint loyalty_budget_snapshots_unique unique (business_id, period_start)
);

create index if not exists loyalty_budget_snapshots_business_idx
  on public.loyalty_budget_snapshots (business_id, period_start desc);

create or replace function public.loyalty_budget_snapshot_create(
  p_business_id uuid,
  p_period_start date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_start date;
  v_end date;
  v_next date;
  v_profile public.business_economic_profiles;
  v_program public.loyalty_programs;
  v_monthly_sales bigint := 0;
  v_reference_budget bigint := 0;
  v_max_budget bigint := 0;
  v_redeemed bigint := 0;
  v_pending bigint := 0;
  v_points_issued integer := 0;
  v_points_redeemed integer := 0;
  v_snapshot public.loyalty_budget_snapshots;
begin
  if v_uid is not null then
    perform public.require_business_role(p_business_id, array['admin']);
  end if;

  v_start := date_trunc(
    'month',
    coalesce(p_period_start, (now() at time zone 'UTC')::date)
  )::date;
  v_end := (v_start + interval '1 month - 1 day')::date;
  v_next := (v_start + interval '1 month')::date;

  select * into v_profile
    from public.business_economic_profiles
   where business_id = p_business_id;
  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if v_profile.daily_avg_sales is not null and v_profile.monthly_operation_days is not null then
    v_monthly_sales := v_profile.daily_avg_sales::bigint * v_profile.monthly_operation_days;
  end if;

  if v_monthly_sales > 0 and v_program.budget_rate is not null then
    v_reference_budget := floor(v_monthly_sales * v_program.budget_rate);
  end if;

  v_max_budget := coalesce(v_profile.max_monthly_reward_budget, v_reference_budget, 0);

  select coalesce(sum(r.points_spent * coalesce(rw.product_price_cop, 0)), 0)::bigint
    into v_redeemed
    from public.loyalty_redemptions r
    join public.loyalty_rewards rw on rw.id = r.reward_id
   where r.business_id = p_business_id
     and r.status = 'delivered'
     and r.created_at >= v_start
     and r.created_at < v_next;

  select coalesce(sum(r.points_spent * coalesce(rw.product_price_cop, 0)), 0)::bigint
    into v_pending
    from public.loyalty_redemptions r
    join public.loyalty_rewards rw on rw.id = r.reward_id
   where r.business_id = p_business_id
     and r.status in ('pending', 'approved')
     and r.created_at >= v_start
     and r.created_at < v_next;

  select coalesce(sum(t.points), 0)::integer
    into v_points_issued
    from public.loyalty_point_transactions t
   where t.business_id = p_business_id
     and t.points > 0
     and t.created_at >= v_start
     and t.created_at < v_next;

  select coalesce(-sum(t.points), 0)::integer
    into v_points_redeemed
    from public.loyalty_point_transactions t
   where t.business_id = p_business_id
     and t.movement_type = 'redemption_debit'
     and t.created_at >= v_start
     and t.created_at < v_next;

  insert into public.loyalty_budget_snapshots (
    business_id, period_start, period_end, monthly_sales_cop,
    budget_rate, reference_budget_cop, max_budget_cop,
    redeemed_cost_cop, pending_cost_cop, points_issued, points_redeemed,
    data, created_by
  ) values (
    p_business_id, v_start, v_end, v_monthly_sales,
    coalesce(v_program.budget_rate, 0), v_reference_budget, v_max_budget,
    v_redeemed, v_pending, v_points_issued, v_points_redeemed,
    jsonb_build_object(
      'profile', to_jsonb(v_profile),
      'program', jsonb_build_object(
        'cop_per_point_unit', v_program.cop_per_point_unit,
        'budget_rate', v_program.budget_rate,
        'points_expiry_days', v_program.points_expiry_days,
        'is_active', v_program.is_active
      ),
      'formula', 'ventas_mensuales = ventas_diarias × días_operación'
    ),
    v_uid
  )
  on conflict (business_id, period_start) do update
    set period_end = excluded.period_end,
        monthly_sales_cop = excluded.monthly_sales_cop,
        budget_rate = excluded.budget_rate,
        reference_budget_cop = excluded.reference_budget_cop,
        max_budget_cop = excluded.max_budget_cop,
        redeemed_cost_cop = excluded.redeemed_cost_cop,
        pending_cost_cop = excluded.pending_cost_cop,
        points_issued = excluded.points_issued,
        points_redeemed = excluded.points_redeemed,
        data = excluded.data,
        created_by = excluded.created_by,
        created_at = now()
  returning * into v_snapshot;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'budget.snapshot',
    'loyalty_budget_snapshot',
    v_snapshot.id::text,
    jsonb_build_object(
      'period_start', v_start,
      'monthly_sales_cop', v_monthly_sales,
      'max_budget_cop', v_max_budget
    )
  );

  return to_jsonb(v_snapshot);
end;
$$;

create or replace function public.loyalty_budget_snapshot_list(
  p_business_id uuid,
  p_limit integer default 12,
  p_offset integer default 0
)
returns table (
  id uuid,
  period_start date,
  period_end date,
  monthly_sales_cop bigint,
  budget_rate numeric,
  reference_budget_cop bigint,
  max_budget_cop bigint,
  redeemed_cost_cop bigint,
  pending_cost_cop bigint,
  points_issued integer,
  points_redeemed integer,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 12), 1), 60);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  return query
    select s.id, s.period_start, s.period_end, s.monthly_sales_cop,
           s.budget_rate, s.reference_budget_cop, s.max_budget_cop,
           s.redeemed_cost_cop, s.pending_cost_cop, s.points_issued,
           s.points_redeemed, s.created_at,
           count(*) over () as total_count
      from public.loyalty_budget_snapshots s
     where s.business_id = p_business_id
     order by s.period_start desc
     limit v_limit offset v_offset;
end;
$$;

create or replace function public.loyalty_budget_snapshot_all(
  p_period_start date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_business record;
  v_count integer := 0;
begin
  if auth.uid() is not null then
    raise exception 'forbidden';
  end if;

  for v_business in
    select id from public.businesses where is_active order by id
  loop
    perform public.loyalty_budget_snapshot_create(v_business.id, p_period_start);
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('businesses_snapshotted', v_count);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. RLS y privilegios
-- ---------------------------------------------------------------------
alter table public.loyalty_campaigns enable row level security;
alter table public.loyalty_budget_snapshots enable row level security;

drop policy if exists loyalty_campaigns_select_member on public.loyalty_campaigns;
create policy loyalty_campaigns_select_member
  on public.loyalty_campaigns for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = loyalty_campaigns.business_id
         and m.user_id = auth.uid()
    )
  );

drop policy if exists loyalty_budget_snapshots_select_staff on public.loyalty_budget_snapshots;
create policy loyalty_budget_snapshots_select_staff
  on public.loyalty_budget_snapshots for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = loyalty_budget_snapshots.business_id
         and m.user_id = auth.uid()
         and m.role in ('admin', 'encargado')
    )
  );

revoke all on public.loyalty_campaigns, public.loyalty_budget_snapshots
  from anon, authenticated;
grant select on public.loyalty_campaigns, public.loyalty_budget_snapshots
  to authenticated;

revoke all on function public.loyalty_campaign_upsert(
  uuid, text, numeric, integer, integer, timestamptz, timestamptz, boolean, text, uuid
) from public;
revoke all on function public.loyalty_campaign_upsert(
  uuid, text, numeric, integer, integer, timestamptz, timestamptz, boolean, text, uuid
) from anon;
grant execute on function public.loyalty_campaign_upsert(
  uuid, text, numeric, integer, integer, timestamptz, timestamptz, boolean, text, uuid
) to authenticated;

revoke all on function public.loyalty_campaign_list(uuid, boolean) from public;
revoke all on function public.loyalty_campaign_list(uuid, boolean) from anon;
grant execute on function public.loyalty_campaign_list(uuid, boolean) to authenticated;

revoke all on function public.loyalty_campaign_delete(uuid, uuid) from public;
revoke all on function public.loyalty_campaign_delete(uuid, uuid) from anon;
grant execute on function public.loyalty_campaign_delete(uuid, uuid) to authenticated;

revoke all on function public.points_expire_due(uuid) from public;
revoke all on function public.points_expire_due(uuid) from anon;
grant execute on function public.points_expire_due(uuid) to authenticated;

revoke all on function public.loyalty_budget_snapshot_create(uuid, date) from public;
revoke all on function public.loyalty_budget_snapshot_create(uuid, date) from anon;
grant execute on function public.loyalty_budget_snapshot_create(uuid, date) to authenticated;

revoke all on function public.loyalty_budget_snapshot_list(uuid, integer, integer) from public;
revoke all on function public.loyalty_budget_snapshot_list(uuid, integer, integer) from anon;
grant execute on function public.loyalty_budget_snapshot_list(uuid, integer, integer) to authenticated;

-- Solo el rol de servicio / cron puede ejecutar los procesos masivos.
revoke all on function public.points_expire_all_due() from public;
revoke all on function public.points_expire_all_due() from anon;
revoke all on function public.points_expire_all_due() from authenticated;
grant execute on function public.points_expire_all_due() to service_role;

revoke all on function public.loyalty_budget_snapshot_all(date) from public;
revoke all on function public.loyalty_budget_snapshot_all(date) from anon;
revoke all on function public.loyalty_budget_snapshot_all(date) from authenticated;
grant execute on function public.loyalty_budget_snapshot_all(date) to service_role;

-- ---------------------------------------------------------------------
-- 8. Programación con pg_cron (si está disponible)
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron no disponible: programa points_expire_due y loyalty_budget_snapshot_create manualmente.';
    return;
  end if;

  begin
    create extension if not exists pg_cron with schema extensions;
  exception when others then
    raise notice 'No se pudo habilitar pg_cron: %', sqlerrm;
    return;
  end;

  begin
    if exists (select 1 from cron.job where jobname = 'loyalty-points-expiry') then
      perform cron.unschedule('loyalty-points-expiry');
    end if;
    perform cron.schedule(
      'loyalty-points-expiry',
      '0 5 * * *',
      'select public.points_expire_all_due();'
    );

    if exists (select 1 from cron.job where jobname = 'loyalty-budget-snapshot') then
      perform cron.unschedule('loyalty-budget-snapshot');
    end if;
    perform cron.schedule(
      'loyalty-budget-snapshot',
      '0 6 1 * *',
      'select public.loyalty_budget_snapshot_all((date_trunc(''month'', now()) - interval ''1 month'')::date);'
    );
  exception when others then
    raise notice 'No se pudieron programar los jobs de pg_cron: %', sqlerrm;
  end;
end
$$;

-- ---------------------------------------------------------------------
-- 9. Comprobaciones rápidas
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'loyalty_point_transactions'
       and column_name = 'expires_at'
  ) then
    raise exception 'falta loyalty_point_transactions.expires_at';
  end if;

  if not exists (
    select 1 from pg_proc
     where proname = 'points_expire_due'
       and pronamespace = 'public'::regnamespace
  ) then
    raise exception 'falta points_expire_due';
  end if;
end;
$$;
