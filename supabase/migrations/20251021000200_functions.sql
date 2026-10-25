-- =====================================================================
-- Funciones de negocio (RPC). Todas las operaciones sensibles son
-- SECURITY DEFINER con search_path fijo y autorización en PostgreSQL.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Utilidades de autorización y frecuencia
-- ---------------------------------------------------------------------
create or replace function public.has_role(p_role public.app_role)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.user_roles
     where user_id = auth.uid()
       and role = p_role
  );
$$;

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.has_role('registrar') or public.has_role('admin');
$$;

create or replace function private.consume_rate_limit(
  p_bucket text,
  p_max integer,
  p_window_seconds integer
)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_count integer;
begin
  insert into private.rate_limits (bucket, window_start, count)
  values (p_bucket, now(), 1)
  on conflict (bucket) do update
    set count = case
          when private.rate_limits.window_start < now() - make_interval(secs => p_window_seconds)
            then 1
          else private.rate_limits.count + 1
        end,
        window_start = case
          when private.rate_limits.window_start < now() - make_interval(secs => p_window_seconds)
            then now()
          else private.rate_limits.window_start
        end
  returning count into v_count;

  if v_count > p_max then
    raise exception 'rate_limited'
      using detail = 'Demasiadas solicitudes. Espera un momento e intenta de nuevo.';
  end if;
end;
$$;

create or replace function private.normalize_redemption_code(p_code text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^a-zA-Z0-9]', '', 'g'));
$$;

create or replace function private.expire_pending_purchases()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  update public.purchases
     set status = 'expired'
   where status = 'pending_claim'
     and expires_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- Consultas del cliente
-- ---------------------------------------------------------------------
create or replace function public.get_my_roles()
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(role::text order by role::text), array[]::text[])
    from public.user_roles
   where user_id = auth.uid();
$$;

create or replace function public.get_my_profile()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', p.id,
    'full_name', p.full_name,
    'email', p.email,
    'created_at', p.created_at
  )
  from public.profiles p
  where p.id = auth.uid();
$$;

create or replace function public.get_program_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_settings public.program_settings;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_settings from public.program_settings where id;
  return jsonb_build_object(
    'cop_per_point_unit', v_settings.cop_per_point_unit,
    'min_purchase_amount', v_settings.min_purchase_amount,
    'max_points_per_purchase', v_settings.max_points_per_purchase,
    'qr_expiry_hours', v_settings.qr_expiry_hours,
    'points_expiry_days', v_settings.points_expiry_days,
    'history_page_size', v_settings.history_page_size
  );
end;
$$;

create or replace function public.get_my_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_balance bigint;
  v_purchase_count integer;
  v_total_spent bigint;
  v_next_reward jsonb;
  v_ready_rewards integer;
  v_pending_redemptions integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select coalesce(sum(points), 0) into v_balance
    from public.points_ledger where customer_id = v_uid;

  select count(*), coalesce(sum(amount_cop), 0)
    into v_purchase_count, v_total_spent
    from public.purchases
   where claimed_by = v_uid and status = 'claimed';

  select count(*) into v_ready_rewards
    from public.rewards
   where is_active and points_cost <= v_balance;

  select count(*) into v_pending_redemptions
    from public.redemptions
   where customer_id = v_uid and status = 'pending_delivery';

  select jsonb_build_object(
           'id', r.id,
           'name', r.name,
           'points_cost', r.points_cost,
           'remaining', r.points_cost - v_balance,
           'image_url', r.image_url
         )
    into v_next_reward
    from public.rewards r
   where r.is_active and r.points_cost > v_balance
   order by r.points_cost asc
   limit 1;

  return jsonb_build_object(
    'points_balance', v_balance,
    'purchase_count', v_purchase_count,
    'total_spent_cop', v_total_spent,
    'ready_rewards', v_ready_rewards,
    'pending_redemptions', v_pending_redemptions,
    'next_reward', v_next_reward
  );
end;
$$;

create or replace function public.list_my_purchases(p_limit integer default null, p_offset integer default 0)
returns table (
  id uuid,
  amount_cop integer,
  points_awarded integer,
  claimed_at timestamptz,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_page integer;
  v_limit integer;
  v_offset integer;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select history_page_size into v_page from public.program_settings where id;
  v_limit := least(greatest(coalesce(p_limit, v_page), 1), 100);
  v_offset := greatest(coalesce(p_offset, 0), 0);

  return query
    select pu.id,
           pu.amount_cop,
           pu.points_awarded,
           pu.claimed_at,
           pu.created_at,
           (select count(*) from public.purchases p2
             where p2.claimed_by = v_uid and p2.status = 'claimed') as total_count
      from public.purchases pu
     where pu.claimed_by = v_uid
       and pu.status = 'claimed'
     order by pu.claimed_at desc, pu.id desc
     limit v_limit offset v_offset;
end;
$$;

create or replace function public.list_active_rewards()
returns table (
  id uuid,
  name text,
  description text,
  image_url text,
  points_cost integer,
  balance bigint,
  remaining integer,
  can_redeem boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_balance bigint;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select coalesce(sum(points), 0) into v_balance
    from public.points_ledger where customer_id = v_uid;

  return query
    select r.id,
           r.name,
           r.description,
           r.image_url,
           r.points_cost,
           v_balance,
           greatest(r.points_cost - v_balance::integer, 0),
           v_balance >= r.points_cost
      from public.rewards r
     where r.is_active
     order by r.points_cost asc, r.name asc;
end;
$$;

create or replace function public.list_my_redemptions()
returns table (
  id uuid,
  reward_name text,
  points_spent integer,
  code text,
  status public.redemption_status,
  created_at timestamptz,
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
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  return query
    select r.id, r.reward_name, r.points_spent, r.code, r.status,
           r.created_at, r.delivered_at, r.cancelled_at
      from public.redemptions r
     where r.customer_id = v_uid
     order by r.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------
-- Reclamación de compras
-- ---------------------------------------------------------------------
create or replace function public.claim_purchase(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_purchase public.purchases;
  v_points integer;
  v_unit integer;
  v_max integer;
  v_balance bigint;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  perform private.consume_rate_limit('claim:' || v_uid::text, 20, 60);

  select *
    into v_purchase
    from public.purchases
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
   for update;

  if not found then
    raise exception 'invalid_token';
  end if;

  if v_purchase.status = 'cancelled' then
    raise exception 'purchase_cancelled';
  end if;
  if v_purchase.status = 'claimed' then
    raise exception 'purchase_already_claimed';
  end if;
  if v_purchase.status = 'expired' or v_now >= v_purchase.expires_at then
    raise exception 'purchase_expired';
  end if;

  v_unit := coalesce(
    (v_purchase.settings_snapshot ->> 'cop_per_point_unit')::integer,
    (select cop_per_point_unit from public.program_settings where id)
  );
  v_max := coalesce(
    (v_purchase.settings_snapshot ->> 'max_points_per_purchase')::integer,
    (select max_points_per_purchase from public.program_settings where id)
  );

  v_unit := greatest(v_unit, 1);
  v_points := least(floor(v_purchase.amount_cop::numeric / v_unit)::integer, v_max);

  if v_points > 0 then
    insert into public.points_ledger (
      customer_id, movement_type, points, purchase_id, idempotency_key, created_by
    ) values (
      v_uid, 'purchase_credit', v_points, v_purchase.id,
      'purchase:' || v_purchase.id::text, null
    );
  end if;

  update public.purchases
     set status = 'claimed',
         claimed_by = v_uid,
         claimed_at = v_now,
         points_awarded = v_points
   where id = v_purchase.id;

  select coalesce(sum(points), 0) into v_balance
    from public.points_ledger where customer_id = v_uid;

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'purchase.claimed',
    'purchase',
    v_purchase.id::text,
    jsonb_build_object(
      'amount_cop', v_purchase.amount_cop,
      'points_awarded', v_points,
      'balance', v_balance
    )
  );

  return jsonb_build_object(
    'purchase_id', v_purchase.id,
    'amount_cop', v_purchase.amount_cop,
    'points_awarded', v_points,
    'balance', v_balance,
    'claimed_at', v_now
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Canje de recompensas por el cliente
-- ---------------------------------------------------------------------
create or replace function public.customer_redeem_reward(
  p_reward_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_reward public.rewards;
  v_balance bigint;
  v_code text;
  v_redemption_id uuid;
  v_existing public.redemptions;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,64}$' then
    raise exception 'invalid_idempotency_key';
  end if;

  -- Serializa todos los canjes/reintentos del mismo cliente.
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text, 0));

  -- Reintento idempotente: devuelve el mismo canje sin volver a descontar.
  select * into v_existing
    from public.redemptions
   where customer_id = v_uid and idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'redemption_id', v_existing.id,
      'reward_name', v_existing.reward_name,
      'points_spent', v_existing.points_spent,
      'code', v_existing.code,
      'status', v_existing.status,
      'created_at', v_existing.created_at,
      'duplicate', true
    );
  end if;

  perform private.consume_rate_limit('redeem:' || v_uid::text, 10, 60);

  select * into v_reward
    from public.rewards
   where id = p_reward_id
   for share;

  if not found or not v_reward.is_active then
    raise exception 'reward_unavailable';
  end if;

  select coalesce(sum(points), 0) into v_balance
    from public.points_ledger where customer_id = v_uid;

  if v_balance < v_reward.points_cost then
    raise exception 'insufficient_points'
      using detail = format('Necesitas %s puntos y tienes %s.', v_reward.points_cost, v_balance);
  end if;

  loop
    v_code := 'TP' || upper(encode(extensions.gen_random_bytes(6), 'hex'));
    exit when not exists (select 1 from public.redemptions where code = v_code);
  end loop;

  insert into public.redemptions (
    customer_id, reward_id, reward_name, points_spent, code, idempotency_key
  ) values (
    v_uid, v_reward.id, v_reward.name, v_reward.points_cost, v_code, p_idempotency_key
  )
  returning id into v_redemption_id;

  insert into public.points_ledger (
    customer_id, movement_type, points, redemption_id, idempotency_key, created_by
  ) values (
    v_uid, 'redemption_debit', -v_reward.points_cost, v_redemption_id,
    'redemption:' || v_redemption_id::text || ':debit', v_uid
  );

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.created',
    'redemption',
    v_redemption_id::text,
    jsonb_build_object(
      'reward_id', v_reward.id,
      'reward_name', v_reward.name,
      'points_spent', v_reward.points_cost
    )
  );

  return jsonb_build_object(
    'redemption_id', v_redemption_id,
    'reward_name', v_reward.name,
    'points_spent', v_reward.points_cost,
    'code', v_code,
    'status', 'pending_delivery',
    'created_at', now(),
    'duplicate', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Operaciones del registrador
-- ---------------------------------------------------------------------
create or replace function public.create_purchase(p_amount_cop integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_settings public.program_settings;
  v_token text;
  v_purchase_id uuid;
  v_expires_at timestamptz;
  v_points_preview integer;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;

  perform private.consume_rate_limit('create_purchase:' || v_uid::text, 30, 60);

  select * into v_settings from public.program_settings where id;

  if p_amount_cop is null or p_amount_cop <= 0 then
    raise exception 'amount_invalid';
  end if;
  if p_amount_cop < v_settings.min_purchase_amount then
    raise exception 'amount_below_minimum'
      using detail = format('La compra mínima es %s COP.', v_settings.min_purchase_amount);
  end if;
  if p_amount_cop > 50000000 then
    raise exception 'amount_too_large';
  end if;

  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_expires_at := now() + make_interval(hours => v_settings.qr_expiry_hours);
  v_points_preview := least(
    floor(p_amount_cop::numeric / v_settings.cop_per_point_unit)::integer,
    v_settings.max_points_per_purchase
  );

  insert into public.purchases (
    amount_cop, registrar_id, token_hash, expires_at, settings_snapshot
  ) values (
    p_amount_cop,
    v_uid,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    v_expires_at,
    jsonb_build_object(
      'cop_per_point_unit', v_settings.cop_per_point_unit,
      'min_purchase_amount', v_settings.min_purchase_amount,
      'max_points_per_purchase', v_settings.max_points_per_purchase,
      'qr_expiry_hours', v_settings.qr_expiry_hours,
      'points_expiry_days', v_settings.points_expiry_days
    )
  )
  returning id into v_purchase_id;

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'purchase.created',
    'purchase',
    v_purchase_id::text,
    jsonb_build_object(
      'amount_cop', p_amount_cop,
      'points_preview', v_points_preview,
      'expires_at', v_expires_at
    )
  );

  return jsonb_build_object(
    'purchase_id', v_purchase_id,
    'token', v_token,
    'amount_cop', p_amount_cop,
    'points_preview', v_points_preview,
    'expires_at', v_expires_at,
    'status', 'pending_claim'
  );
end;
$$;

create or replace function public.staff_cancel_purchase(p_purchase_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_purchase public.purchases;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;
  if v_reason is null or length(v_reason) > 300 then raise exception 'invalid_reason'; end if;

  perform private.consume_rate_limit('cancel_purchase:' || v_uid::text, 20, 60);

  select * into v_purchase from public.purchases where id = p_purchase_id for update;
  if not found then raise exception 'purchase_not_found'; end if;
  if v_purchase.status = 'claimed' then raise exception 'purchase_already_claimed'; end if;
  if v_purchase.status = 'cancelled' then raise exception 'purchase_already_cancelled'; end if;

  update public.purchases
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = v_uid,
         cancellation_reason = v_reason
   where id = p_purchase_id;

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'purchase.cancelled',
    'purchase',
    p_purchase_id::text,
    jsonb_build_object('reason', v_reason, 'previous_status', v_purchase.status)
  );

  return jsonb_build_object('purchase_id', p_purchase_id, 'status', 'cancelled');
end;
$$;

create or replace function public.staff_list_customers(
  p_search text default '',
  p_limit integer default 20,
  p_offset integer default 0,
  p_sort text default 'created_at',
  p_direction text default 'desc'
)
returns table (
  id uuid,
  full_name text,
  email text,
  points_balance bigint,
  purchase_count integer,
  total_spent bigint,
  created_at timestamptz,
  total_count bigint
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
  if not public.is_staff() then raise exception 'forbidden'; end if;

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
           coalesce((select sum(l.points) from public.points_ledger l where l.customer_id = p.id), 0)::bigint as points_balance,
           (select count(*) from public.purchases pu where pu.claimed_by = p.id and pu.status = 'claimed')::integer as purchase_count,
           coalesce((select sum(pu.amount_cop) from public.purchases pu where pu.claimed_by = p.id and pu.status = 'claimed'), 0)::bigint as total_spent,
           p.created_at,
           count(*) over () as total_count
      from public.profiles p
     where exists (
             select 1 from public.user_roles r
              where r.user_id = p.id and r.role = 'customer'
           )
       and ($1 = '' or p.full_name ilike '%%' || $1 || '%%' or p.email ilike '%%' || $1 || '%%')
     order by %s %s, p.id
     limit $2 offset $3
  $query$, v_order, v_dir)
  using v_search, v_limit, v_offset;
end;
$$;

create or replace function public.staff_get_customer(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;

  if not exists (select 1 from public.profiles where id = p_customer_id) then
    raise exception 'customer_not_found';
  end if;

  select jsonb_build_object(
    'profile', jsonb_build_object(
      'id', p.id,
      'full_name', p.full_name,
      'email', p.email,
      'created_at', p.created_at
    ),
    'points_balance', coalesce((select sum(l.points) from public.points_ledger l where l.customer_id = p.id), 0),
    'purchase_count', (select count(*) from public.purchases pu where pu.claimed_by = p.id and pu.status = 'claimed'),
    'total_spent', coalesce((select sum(pu.amount_cop) from public.purchases pu where pu.claimed_by = p.id and pu.status = 'claimed'), 0),
    'purchases', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.claimed_at desc)
      from (
        select pu.id, pu.amount_cop, pu.points_awarded, pu.claimed_at, pu.status
          from public.purchases pu
         where pu.claimed_by = p.id and pu.status = 'claimed'
         order by pu.claimed_at desc
         limit 50
      ) x
    ), '[]'::jsonb),
    'movements', coalesce((
      select jsonb_agg(to_jsonb(y) order by y.created_at desc)
      from (
        select l.id, l.movement_type, l.points, l.reason, l.created_at
          from public.points_ledger l
         where l.customer_id = p.id
         order by l.created_at desc
         limit 50
      ) y
    ), '[]'::jsonb),
    'redemptions', coalesce((
      select jsonb_agg(to_jsonb(z) order by z.created_at desc)
      from (
        select r.id, r.reward_name, r.points_spent, r.code, r.status, r.created_at, r.delivered_at
          from public.redemptions r
         where r.customer_id = p.id
         order by r.created_at desc
         limit 50
      ) z
    ), '[]'::jsonb)
  )
  into v_result
  from public.profiles p
  where p.id = p_customer_id;

  return v_result;
end;
$$;

create or replace function public.staff_list_purchases(
  p_limit integer default 20,
  p_offset integer default 0,
  p_status text default null
)
returns table (
  id uuid,
  amount_cop integer,
  status public.purchase_status,
  points_awarded integer,
  created_at timestamptz,
  expires_at timestamptz,
  claimed_at timestamptz,
  customer_name text,
  customer_email text,
  registrar_name text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;

  perform private.expire_pending_purchases();

  return query
    select pu.id,
           pu.amount_cop,
           pu.status,
           pu.points_awarded,
           pu.created_at,
           pu.expires_at,
           pu.claimed_at,
           c.full_name,
           c.email,
           reg.full_name,
           (select count(*) from public.purchases p2
             where p_status is null or p2.status::text = p_status) as total_count
      from public.purchases pu
      left join public.profiles c on c.id = pu.claimed_by
      left join public.profiles reg on reg.id = pu.registrar_id
     where p_status is null or pu.status::text = p_status
     order by pu.created_at desc
     limit v_limit offset v_offset;
end;
$$;

create or replace function public.staff_list_redemptions(
  p_status text default null,
  p_limit integer default 100
)
returns table (
  id uuid,
  reward_name text,
  points_spent integer,
  code text,
  status public.redemption_status,
  created_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  customer_name text,
  customer_email text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;

  return query
    select r.id, r.reward_name, r.points_spent, r.code, r.status,
           r.created_at, r.delivered_at, r.cancelled_at,
           p.full_name, p.email
      from public.redemptions r
      join public.profiles p on p.id = r.customer_id
     where p_status is null or r.status::text = p_status
     order by (r.status = 'pending_delivery') desc, r.created_at desc
     limit v_limit;
end;
$$;

create or replace function public.staff_lookup_redemption(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  v_result jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;

  perform private.consume_rate_limit('lookup_redemption:' || v_uid::text, 60, 60);

  v_code := private.normalize_redemption_code(p_code);
  if v_code = '' then raise exception 'redemption_not_found'; end if;

  select jsonb_build_object(
    'id', r.id,
    'code', r.code,
    'status', r.status,
    'reward_name', r.reward_name,
    'points_spent', r.points_spent,
    'created_at', r.created_at,
    'delivered_at', r.delivered_at,
    'cancelled_at', r.cancelled_at,
    'customer_name', p.full_name,
    'customer_email', p.email
  )
  into v_result
  from public.redemptions r
  join public.profiles p on p.id = r.customer_id
  where r.code = v_code;

  if v_result is null then
    raise exception 'redemption_not_found';
  end if;

  return v_result;
end;
$$;

create or replace function public.staff_confirm_redemption(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  v_redemption public.redemptions;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;

  perform private.consume_rate_limit('confirm_redemption:' || v_uid::text, 40, 60);

  v_code := private.normalize_redemption_code(p_code);
  select * into v_redemption from public.redemptions where code = v_code for update;
  if not found then raise exception 'redemption_not_found'; end if;
  if v_redemption.status = 'redeemed' then raise exception 'redemption_already_redeemed'; end if;
  if v_redemption.status = 'cancelled' then raise exception 'redemption_cancelled'; end if;

  update public.redemptions
     set status = 'redeemed',
         delivered_at = now(),
         delivered_by = v_uid
   where id = v_redemption.id;

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.delivered',
    'redemption',
    v_redemption.id::text,
    jsonb_build_object('code', v_code, 'reward_name', v_redemption.reward_name)
  );

  return public.staff_lookup_redemption(v_code);
end;
$$;

create or replace function public.staff_cancel_redemption(p_redemption_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_redemption public.redemptions;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;
  if v_reason is null or length(v_reason) > 300 then raise exception 'invalid_reason'; end if;

  perform private.consume_rate_limit('cancel_redemption:' || v_uid::text, 20, 60);

  select * into v_redemption from public.redemptions where id = p_redemption_id for update;
  if not found then raise exception 'redemption_not_found'; end if;
  if v_redemption.status <> 'pending_delivery' then
    raise exception 'redemption_not_pending';
  end if;

  update public.redemptions
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = v_uid,
         cancellation_reason = v_reason
   where id = v_redemption.id;

  insert into public.points_ledger (
    customer_id, movement_type, points, redemption_id, idempotency_key, reason, created_by
  ) values (
    v_redemption.customer_id,
    'redemption_refund',
    v_redemption.points_spent,
    v_redemption.id,
    'redemption:' || v_redemption.id::text || ':refund',
    v_reason,
    v_uid
  );

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.cancelled',
    'redemption',
    v_redemption.id::text,
    jsonb_build_object('reason', v_reason, 'points_refunded', v_redemption.points_spent)
  );

  return jsonb_build_object(
    'redemption_id', v_redemption.id,
    'status', 'cancelled',
    'points_refunded', v_redemption.points_spent
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Administración: configuración, recompensas, roles y auditoría
-- ---------------------------------------------------------------------
create or replace function public.admin_get_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_settings public.program_settings;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not public.has_role('admin') then raise exception 'forbidden'; end if;

  select * into v_settings from public.program_settings where id;
  select to_jsonb(v_settings) || jsonb_build_object(
    'updated_by_email', (select email from public.profiles where id = v_settings.updated_by)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.admin_update_settings(p_settings jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_before public.program_settings;
  v_after public.program_settings;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.has_role('admin') then raise exception 'forbidden'; end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'invalid_settings';
  end if;

  perform private.consume_rate_limit('update_settings:' || v_uid::text, 20, 60);

  select * into v_before from public.program_settings where id for update;

  update public.program_settings
     set cop_per_point_unit = coalesce(
           nullif(p_settings ->> 'cop_per_point_unit', '')::integer,
           cop_per_point_unit
         ),
         min_purchase_amount = coalesce(
           nullif(p_settings ->> 'min_purchase_amount', '')::integer,
           min_purchase_amount
         ),
         max_points_per_purchase = coalesce(
           nullif(p_settings ->> 'max_points_per_purchase', '')::integer,
           max_points_per_purchase
         ),
         qr_expiry_hours = coalesce(
           nullif(p_settings ->> 'qr_expiry_hours', '')::integer,
           qr_expiry_hours
         ),
         points_expiry_days = case
           when p_settings ? 'points_expiry_days'
             then nullif(p_settings ->> 'points_expiry_days', '')::integer
           else points_expiry_days
         end,
         history_page_size = coalesce(
           nullif(p_settings ->> 'history_page_size', '')::integer,
           history_page_size
         ),
         updated_by = v_uid
   where id
  returning * into v_after;

  insert into public.config_history (changed_by, before_value, after_value)
  values (v_uid, to_jsonb(v_before), to_jsonb(v_after));

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'settings.updated',
    'program_settings',
    'singleton',
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_after))
  );

  return to_jsonb(v_after);
end;
$$;

create or replace function public.admin_list_rewards()
returns table (
  id uuid,
  name text,
  description text,
  image_url text,
  points_cost integer,
  is_active boolean,
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
  if not public.has_role('admin') then raise exception 'forbidden'; end if;

  return query
    select r.id, r.name, r.description, r.image_url, r.points_cost, r.is_active,
           r.created_at, r.updated_at,
           (select count(*) from public.redemptions d where d.reward_id = r.id) as times_redeemed
      from public.rewards r
     order by r.is_active desc, r.points_cost asc, r.name asc;
end;
$$;

create or replace function public.admin_upsert_reward(
  p_id uuid default null,
  p_name text default null,
  p_description text default '',
  p_points_cost integer default null,
  p_image_url text default null,
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
  if not public.has_role('admin') then raise exception 'forbidden'; end if;
  if length(v_name) < 2 or length(v_name) > 120 then raise exception 'invalid_reward_name'; end if;
  if p_points_cost is null or p_points_cost <= 0 or p_points_cost > 1000000 then
    raise exception 'invalid_reward_cost';
  end if;
  if length(coalesce(p_description, '')) > 500 then
    raise exception 'invalid_reward_description';
  end if;
  if p_image_url is not null and btrim(p_image_url) <> '' and p_image_url !~ '^https?://' then
    raise exception 'invalid_image_url';
  end if;

  perform private.consume_rate_limit('upsert_reward:' || v_uid::text, 30, 60);

  begin
    if p_id is null then
      insert into public.rewards (name, description, image_url, points_cost, is_active, created_by)
      values (
        v_name,
        btrim(coalesce(p_description, '')),
        nullif(btrim(coalesce(p_image_url, '')), ''),
        p_points_cost,
        coalesce(p_is_active, true),
        v_uid
      )
      returning id into v_id;
    else
      update public.rewards
         set name = v_name,
             description = btrim(coalesce(p_description, '')),
             image_url = nullif(btrim(coalesce(p_image_url, '')), ''),
             points_cost = p_points_cost,
             is_active = coalesce(p_is_active, true)
       where id = p_id
      returning id into v_id;
      if v_id is null then raise exception 'reward_not_found'; end if;
    end if;
  exception
    when unique_violation then
      raise exception 'reward_name_duplicate';
  end;

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    case when p_id is null then 'reward.created' else 'reward.updated' end,
    'reward',
    v_id::text,
    jsonb_build_object(
      'name', v_name,
      'points_cost', p_points_cost,
      'is_active', p_is_active
    )
  );

  return (select to_jsonb(r) from public.rewards r where r.id = v_id);
end;
$$;

create or replace function public.admin_list_staff()
returns table (
  user_id uuid,
  full_name text,
  email text,
  roles text[],
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not public.has_role('admin') then raise exception 'forbidden'; end if;

  return query
    select p.id, p.full_name, p.email,
           array_agg(r.role::text order by r.role::text),
           p.created_at
      from public.profiles p
      join public.user_roles r on r.user_id = p.id
     where r.role in ('registrar', 'admin')
     group by p.id, p.full_name, p.email, p.created_at
     order by p.created_at asc;
end;
$$;

create or replace function public.admin_search_profiles(p_query text default '')
returns table (
  user_id uuid,
  full_name text,
  email text,
  roles text[],
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_query text := btrim(coalesce(p_query, ''));
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not public.has_role('admin') then raise exception 'forbidden'; end if;

  v_query := replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_');

  return query
    select p.id, p.full_name, p.email,
           coalesce(array_agg(r.role::text order by r.role::text) filter (where r.role is not null), array[]::text[]),
           p.created_at
      from public.profiles p
      left join public.user_roles r on r.user_id = p.id
     where v_query = ''
        or p.email ilike '%' || v_query || '%'
        or p.full_name ilike '%' || v_query || '%'
     group by p.id, p.full_name, p.email, p.created_at
     order by p.created_at desc
     limit 25;
end;
$$;

create or replace function public.admin_grant_role(p_user_id uuid, p_role public.app_role)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.has_role('admin') then raise exception 'forbidden'; end if;
  if p_role not in ('registrar', 'admin') then raise exception 'invalid_role'; end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'user_not_found';
  end if;

  perform private.consume_rate_limit('grant_role:' || v_uid::text, 20, 60);

  insert into public.user_roles (user_id, role, granted_by)
  values (p_user_id, p_role, v_uid)
  on conflict (user_id, role) do nothing;

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'role.granted',
    'user_role',
    p_user_id::text,
    jsonb_build_object('role', p_role)
  );

  return jsonb_build_object('user_id', p_user_id, 'role', p_role, 'granted', true);
end;
$$;

create or replace function public.admin_revoke_role(p_user_id uuid, p_role public.app_role)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_admin_count integer;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.has_role('admin') then raise exception 'forbidden'; end if;
  if p_role not in ('registrar', 'admin') then raise exception 'invalid_role'; end if;

  perform private.consume_rate_limit('revoke_role:' || v_uid::text, 20, 60);

  if p_role = 'admin' then
    select count(*) into v_admin_count from public.user_roles where role = 'admin';
    if v_admin_count <= 1 then raise exception 'last_admin'; end if;
    if p_user_id = v_uid then raise exception 'cannot_revoke_own_admin'; end if;
  end if;

  delete from public.user_roles where user_id = p_user_id and role = p_role;
  if not found then raise exception 'role_not_found'; end if;

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'role.revoked',
    'user_role',
    p_user_id::text,
    jsonb_build_object('role', p_role)
  );

  return jsonb_build_object('user_id', p_user_id, 'role', p_role, 'revoked', true);
end;
$$;

create or replace function public.admin_get_audit_log(p_limit integer default 50, p_offset integer default 0)
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
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not public.has_role('admin') then raise exception 'forbidden'; end if;

  return query
    select a.id, a.actor_email, a.operation, a.entity_type, a.entity_id, a.metadata, a.created_at
      from public.audit_log a
     order by a.created_at desc
     limit v_limit offset v_offset;
end;
$$;

create or replace function public.admin_get_config_history(p_limit integer default 30)
returns table (
  id bigint,
  changed_by_email text,
  before_value jsonb,
  after_value jsonb,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 100);
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not public.has_role('admin') then raise exception 'forbidden'; end if;

  return query
    select c.id, p.email, c.before_value, c.after_value, c.created_at
      from public.config_history c
      left join public.profiles p on p.id = c.changed_by
     order by c.created_at desc
     limit v_limit;
end;
$$;

-- Vencimiento de puntos: se ejecuta explícitamente (por ejemplo con pg_cron).
-- Expira créditos antiguos hasta donde el saldo actual lo permita. La clave de
-- idempotencia evita aplicar dos veces el vencimiento del mismo crédito.
create or replace function public.admin_expire_points()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_days integer;
  v_credit record;
  v_balance bigint;
  v_amount integer;
  v_expired integer := 0;
  v_points integer := 0;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.has_role('admin') then raise exception 'forbidden'; end if;

  select points_expiry_days into v_days from public.program_settings where id;
  if v_days is null then raise exception 'expiry_disabled'; end if;

  for v_credit in
    select l.id, l.customer_id, l.points
      from public.points_ledger l
     where l.movement_type = 'purchase_credit'
       and l.created_at < now() - make_interval(days => v_days)
       and not exists (
         select 1 from public.points_ledger e
          where e.idempotency_key = 'expiry:' || l.id::text
       )
  loop
    select coalesce(sum(points), 0) into v_balance
      from public.points_ledger where customer_id = v_credit.customer_id;

    if v_balance > 0 then
      v_amount := least(v_credit.points, v_balance::integer);
      insert into public.points_ledger (
        customer_id, movement_type, points, reason, idempotency_key, created_by
      ) values (
        v_credit.customer_id,
        'expiry_debit',
        -v_amount,
        format('Vencimiento del crédito %s', v_credit.id),
        'expiry:' || v_credit.id::text,
        v_uid
      );
      v_expired := v_expired + 1;
      v_points := v_points + v_amount;
    end if;
  end loop;

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'points.expired',
    'points_ledger',
    null,
    jsonb_build_object('credits_expired', v_expired, 'points_expired', v_points, 'days', v_days)
  );

  return jsonb_build_object('credits_expired', v_expired, 'points_expired', v_points, 'days', v_days);
end;
$$;
