-- =====================================================================
-- Flujo operativo simplificado (23/10/2026)
--
-- - Dos tipos de usuario: administrador y cliente.
--   El rol histórico 'registrar' se conserva en el enum para no romper
--   datos existentes, pero deja de otorgar acceso al panel.
-- - El administrador genera el QR de compra, consulta clientes y aplica
--   el canje de una recompensa. El cliente solo consulta su saldo,
--   catálogo e historial.
-- - El canje descuenta los puntos de inmediato y queda como entregado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Administrador inicial por correo
-- ---------------------------------------------------------------------
-- La lista de correos que reciben `admin` al registrarse se configura por
-- entorno y NO se versiona. Antes del primer registro, ejecuta:
--
--   insert into private.bootstrap_admins (email)
--   values ('correo-del-administrador@dominio.com')
--   on conflict (email) do nothing;
--
-- El correo queda solo en la base de datos; nunca en este repositorio.
create table if not exists private.bootstrap_admins (
  email text primary key,
  created_at timestamptz not null default now(),
  constraint bootstrap_admins_email_normalized
    check (email = lower(btrim(email)))
);

revoke all on private.bootstrap_admins from public;
revoke all on private.bootstrap_admins from anon, authenticated;

-- Si la cuenta ya existía antes de esta migración, se habilita ahora.
insert into public.user_roles (user_id, role)
select u.id, 'admin'
  from auth.users u
  join private.bootstrap_admins b on lower(btrim(u.email)) = b.email
on conflict (user_id, role) do nothing;

-- ---------------------------------------------------------------------
-- Alta de usuarios: cliente siempre; administrador solo si está en la
-- lista de arranque. El resto de roles se gestiona por base de datos.
-- ---------------------------------------------------------------------
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
      ''
    ),
    coalesce(new.email, '')
  )
  on conflict (id) do update
    set email = excluded.email,
        full_name = case
          when public.profiles.full_name = '' then excluded.full_name
          else public.profiles.full_name
        end;

  insert into public.user_roles (user_id, role)
  values (new.id, 'customer')
  on conflict do nothing;

  if exists (
    select 1
      from private.bootstrap_admins b
     where b.email = lower(btrim(coalesce(new.email, '')))
  ) then
    insert into public.user_roles (user_id, role)
    values (new.id, 'admin')
    on conflict do nothing;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Autorización: el panel es exclusivamente administrativo.
-- ---------------------------------------------------------------------
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.has_role('admin');
$$;

-- Un canje entregado puede anularse conservando la trazabilidad de entrega.
alter table public.redemptions
  drop constraint redemptions_delivery_consistency;

alter table public.redemptions
  add constraint redemptions_delivery_consistency check (
    (status = 'redeemed' and delivered_at is not null and delivered_by is not null)
    or (status = 'pending_delivery' and delivered_at is null and delivered_by is null)
    or (status = 'cancelled')
  );

-- ---------------------------------------------------------------------
-- Listado de clientes: excluye cuentas administrativas y mantiene los
-- filtros/orden existentes. El frontend ordena por puntos descendente.
-- ---------------------------------------------------------------------
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
       and not exists (
             select 1 from public.user_roles r
              where r.user_id = p.id and r.role = 'admin'
           )
       and ($1 = '' or p.full_name ilike '%%' || $1 || '%%' or p.email ilike '%%' || $1 || '%%')
     order by %s %s, p.id
     limit $2 offset $3
  $query$, v_order, v_dir)
  using v_search, v_limit, v_offset;
end;
$$;

-- ---------------------------------------------------------------------
-- Detalle de cliente: añade la fecha de cancelación de canjes.
-- ---------------------------------------------------------------------
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
        select r.id, r.reward_name, r.points_spent, r.code, r.status,
               r.created_at, r.delivered_at, r.cancelled_at
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

-- ---------------------------------------------------------------------
-- Canje aplicado por el administrador
-- ---------------------------------------------------------------------
create or replace function public.admin_redeem_reward(
  p_customer_id uuid,
  p_reward_id uuid,
  p_idempotency_key text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_reward public.rewards%rowtype;
  v_customer public.profiles%rowtype;
  v_balance bigint;
  v_code text;
  v_redemption_id uuid;
  v_existing public.redemptions%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_created_at timestamptz := now();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;

  if p_customer_id is null or p_reward_id is null then
    raise exception 'invalid_request';
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,64}$' then
    raise exception 'invalid_idempotency_key';
  end if;
  if v_reason is not null and length(v_reason) > 300 then
    raise exception 'invalid_reason';
  end if;

  select * into v_customer from public.profiles where id = p_customer_id;
  if not found then raise exception 'customer_not_found'; end if;

  -- Serializa canjes y reintentos del mismo cliente.
  perform pg_advisory_xact_lock(hashtextextended(p_customer_id::text, 0));

  select * into v_existing
    from public.redemptions
   where customer_id = p_customer_id
     and idempotency_key = p_idempotency_key;
  if found then
    select coalesce(sum(points), 0) into v_balance
      from public.points_ledger where customer_id = p_customer_id;
    return jsonb_build_object(
      'redemption_id', v_existing.id,
      'reward_name', v_existing.reward_name,
      'points_spent', v_existing.points_spent,
      'code', v_existing.code,
      'balance', v_balance,
      'created_at', v_existing.created_at,
      'duplicate', true
    );
  end if;

  perform private.consume_rate_limit('admin_redeem:' || v_uid::text, 60, 60);

  select * into v_reward
    from public.rewards
   where id = p_reward_id
   for share;

  if not found or not v_reward.is_active then
    raise exception 'reward_unavailable';
  end if;

  select coalesce(sum(points), 0) into v_balance
    from public.points_ledger where customer_id = p_customer_id;

  if v_balance < v_reward.points_cost then
    raise exception 'insufficient_points'
      using detail = format('El cliente tiene %s puntos y la recompensa cuesta %s.',
                            v_balance, v_reward.points_cost);
  end if;

  loop
    v_code := 'TP' || upper(encode(extensions.gen_random_bytes(6), 'hex'));
    exit when not exists (select 1 from public.redemptions where code = v_code);
  end loop;

  insert into public.redemptions (
    customer_id, reward_id, reward_name, points_spent, code, status,
    idempotency_key, created_at, delivered_at, delivered_by
  ) values (
    p_customer_id, v_reward.id, v_reward.name, v_reward.points_cost, v_code,
    'redeemed', p_idempotency_key, v_created_at, v_created_at, v_uid
  )
  returning id into v_redemption_id;

  insert into public.points_ledger (
    customer_id, movement_type, points, redemption_id, reason,
    idempotency_key, created_by
  ) values (
    p_customer_id, 'redemption_debit', -v_reward.points_cost, v_redemption_id,
    v_reason, 'redemption:' || v_redemption_id::text || ':debit', v_uid
  );

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.applied_by_admin',
    'redemption',
    v_redemption_id::text,
    jsonb_build_object(
      'customer_id', p_customer_id,
      'customer_email', v_customer.email,
      'reward_id', v_reward.id,
      'reward_name', v_reward.name,
      'points_spent', v_reward.points_cost,
      'balance_after', v_balance - v_reward.points_cost,
      'reason', v_reason
    )
  );

  return jsonb_build_object(
    'redemption_id', v_redemption_id,
    'reward_name', v_reward.name,
    'points_spent', v_reward.points_cost,
    'code', v_code,
    'balance', v_balance - v_reward.points_cost,
    'created_at', v_created_at,
    'duplicate', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Anulación de un canje aplicado por error (devuelve los puntos)
-- ---------------------------------------------------------------------
create or replace function public.admin_cancel_redemption(
  p_redemption_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_redemption public.redemptions%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_balance bigint;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if not public.is_staff() then raise exception 'forbidden'; end if;
  if v_reason is null or length(v_reason) > 300 then raise exception 'invalid_reason'; end if;

  select * into v_redemption
    from public.redemptions
   where id = p_redemption_id
   for update;

  if not found then raise exception 'redemption_not_found'; end if;
  if v_redemption.status = 'cancelled' then raise exception 'redemption_cancelled'; end if;

  update public.redemptions
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = v_uid,
         cancellation_reason = v_reason
   where id = v_redemption.id;

  insert into public.points_ledger (
    customer_id, movement_type, points, redemption_id, reason,
    idempotency_key, created_by
  ) values (
    v_redemption.customer_id,
    'redemption_refund',
    v_redemption.points_spent,
    v_redemption.id,
    v_reason,
    'redemption:' || v_redemption.id::text || ':refund',
    v_uid
  );

  select coalesce(sum(points), 0) into v_balance
    from public.points_ledger where customer_id = v_redemption.customer_id;

  insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.cancelled_by_admin',
    'redemption',
    v_redemption.id::text,
    jsonb_build_object(
      'customer_id', v_redemption.customer_id,
      'reward_name', v_redemption.reward_name,
      'points_refunded', v_redemption.points_spent,
      'balance_after', v_balance,
      'reason', v_reason
    )
  );

  return jsonb_build_object(
    'redemption_id', v_redemption.id,
    'status', 'cancelled',
    'points_refunded', v_redemption.points_spent,
    'balance', v_balance
  );
end;
$$;

-- El canje deja de ser una acción del cliente: ahora lo aplica caja.
create or replace function public.customer_redeem_reward(
  p_reward_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'redemption_requires_admin'
    using detail = 'Un administrador debe aplicar el canje desde el panel.';
end;
$$;

-- ---------------------------------------------------------------------
-- Permisos: solo las RPC nuevas para administradores autenticados.
-- ---------------------------------------------------------------------
revoke execute on function public.customer_redeem_reward(uuid, text) from authenticated;
revoke execute on function public.admin_redeem_reward(uuid, uuid, text, text) from public;
revoke execute on function public.admin_cancel_redemption(uuid, text) from public;
grant execute on function public.admin_redeem_reward(uuid, uuid, text, text) to authenticated;
grant execute on function public.admin_cancel_redemption(uuid, text) to authenticated;
