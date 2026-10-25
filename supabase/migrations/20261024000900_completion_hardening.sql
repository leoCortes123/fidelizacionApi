-- =====================================================================
-- Fase 0 — Endurecimiento, roles por negocio, afiliación y completitud
--
-- Esta migración es aditiva sobre 0001..0008 y corrige:
--   1. Autorización canónica por negocio con text[] (paridad local/remoto).
--   2. Roles de aplicación que incluyen business_memberships.
--   3. Listado de negocios con rol y permiso del usuario.
--   4. Programa y perfil económico creados por defecto al registrar negocio.
--   5. Afiliación de clientes por enlace/QR (business_join).
--   6. Búsqueda de perfiles por negocio (para crear encargados).
--   7. Redenciones del propio cliente y reemisión de token QR.
--   8. Registro de compra con acumulación segura e idempotente.
--   9. Corrección del orden de argumentos de loyalty_transaction_post
--      (todas las llamadas existentes usaban el orden correcto, pero la
--      definición tenía idempotency_key/created_by en posiciones distintas).
--  10. Guardas de rol y pertenencia en points_* y recompensas disponibles.
--  11. Columna cancelled_by que redemption_cancel ya intentaba escribir.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Columna de auditoría de cancelación (redemption_cancel la usa)
-- ---------------------------------------------------------------------
alter table public.loyalty_redemptions
  add column if not exists cancelled_by uuid references public.profiles (id) on delete set null;

-- ---------------------------------------------------------------------
-- 1. Autorización por negocio con text[]
--    Se elimina la versión enum[] para evitar ambigüedad y se deja una
--    sola firma canónica.
-- ---------------------------------------------------------------------
drop function if exists public.require_business_role(uuid, public.business_role[]);

create or replace function public.require_business_role(
  p_business_id uuid,
  p_allowed text[]
)
returns public.business_memberships
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_membership public.business_memberships;
begin
  v_membership := public.business_current_membership(p_business_id);

  if not (v_membership.role::text = any(p_allowed)) then
    raise exception 'forbidden';
  end if;

  return v_membership;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Roles de aplicación (legacy + membresías por negocio)
-- ---------------------------------------------------------------------
create or replace function public.get_my_app_roles()
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(distinct r order by r), array[]::text[])
  from (
    select role::text as r
      from public.user_roles
     where user_id = auth.uid()
    union all
    select case role
             when 'admin' then 'admin'
             when 'encargado' then 'registrar'
             else 'customer'
           end
      from public.business_memberships
     where user_id = auth.uid()
  ) s;
$$;

-- ---------------------------------------------------------------------
-- 3. Registro de negocio: crea programa y perfil económico por defecto
-- ---------------------------------------------------------------------
create or replace function public.business_register(
  p_business_name text,
  p_slug text,
  p_timezone text default 'America/Bogota'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_business_id uuid;
  v_membership_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if length(btrim(coalesce(p_business_name, ''))) < 2 then
    raise exception 'invalid_business_name';
  end if;
  if length(btrim(coalesce(p_slug, ''))) < 2 then
    raise exception 'invalid_business_slug';
  end if;

  begin
    insert into public.businesses (name, slug, timezone, created_by)
    values (btrim(p_business_name), lower(btrim(p_slug)), coalesce(p_timezone, 'America/Bogota'), v_uid)
    returning id into v_business_id;
  exception
    when unique_violation then
      raise exception 'business_slug_duplicate';
  end;

  insert into public.business_memberships (business_id, user_id, role, created_by)
  values (v_business_id, v_uid, 'admin', v_uid)
  returning id into v_membership_id;

  -- Programa inactivo con valores iniciales: la UI muestra "sin activar".
  insert into public.loyalty_programs (business_id)
  values (v_business_id)
  on conflict (business_id) do nothing;

  insert into public.business_economic_profiles (business_id)
  values (v_business_id)
  on conflict (business_id) do nothing;

  insert into public.business_audit_logs (business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata)
  values (
    v_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'business.created',
    'business',
    v_business_id::text,
    jsonb_build_object('name', p_business_name, 'slug', p_slug, 'timezone', coalesce(p_timezone, 'America/Bogota'))
  );

  return jsonb_build_object(
    'business_id', v_business_id,
    'membership_id', v_membership_id,
    'role', 'admin',
    'created_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Listar negocios con el rol y permiso del usuario
-- ---------------------------------------------------------------------
drop function if exists public.businesses_list();

create or replace function public.businesses_list()
returns table (
  id uuid,
  name text,
  slug text,
  timezone text,
  operating_days smallint[],
  is_active boolean,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  role public.business_role,
  can_approve_redemptions boolean
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
    select b.id, b.name, b.slug, b.timezone, b.operating_days, b.is_active,
           b.created_by, b.created_at, b.updated_at,
           m.role, m.can_approve_redemptions
      from public.businesses b
      join public.business_memberships m
        on m.business_id = b.id and m.user_id = v_uid
     order by b.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Obtener el programa sin fallar cuando aún no está configurado
-- ---------------------------------------------------------------------
create or replace function public.loyalty_program_get(
  p_business_id uuid
)
returns public.loyalty_programs
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_program public.loyalty_programs;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  if not exists (
    select 1 from public.business_memberships
     where business_id = p_business_id and user_id = v_uid
  ) then
    raise exception 'business_not_found_or_no_access';
  end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found then
    -- Valores iniciales en memoria: no se escribe en una función stable.
    v_program.id := '00000000-0000-0000-0000-000000000000'::uuid;
    v_program.business_id := p_business_id;
    v_program.cop_per_point_unit := 1000;
    v_program.points_per_cop_unit := 100;
    v_program.points_expiry_days := 365;
    v_program.budget_rate := 0.0100;
    v_program.first_purchase_bonus_points := 0;
    v_program.recurrence_bonus_points := 0;
    v_program.referral_bonus_points := 0;
    v_program.qr_expiry_hours := 24;
    v_program.is_active := false;
  end if;

  return v_program;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Configurar programa con activación explícita
-- ---------------------------------------------------------------------
drop function if exists public.loyalty_program_configure(
  uuid, integer, integer, integer, numeric, integer, integer, integer, integer
);

create or replace function public.loyalty_program_configure(
  p_business_id uuid,
  p_cop_per_point_unit integer,
  p_points_per_cop_unit integer,
  p_points_expiry_days integer,
  p_budget_rate numeric,
  p_first_purchase_bonus_points integer,
  p_recurrence_bonus_points integer,
  p_referral_bonus_points integer,
  p_qr_expiry_hours integer,
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
  v_before jsonb;
  v_after jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  if p_cop_per_point_unit < 100 or p_cop_per_point_unit > 1000000 then
    raise exception 'invalid_cop_per_point_unit';
  end if;
  if p_points_per_cop_unit < 1 or p_points_per_cop_unit > 1000000 then
    raise exception 'invalid_points_per_cop_unit';
  end if;
  if p_points_expiry_days < 1 or p_points_expiry_days > 3650 then
    raise exception 'invalid_points_expiry_days';
  end if;
  if p_budget_rate < 0 or p_budget_rate > 1 then
    raise exception 'invalid_budget_rate';
  end if;
  if p_qr_expiry_hours < 1 or p_qr_expiry_hours > 168 then
    raise exception 'invalid_qr_expiry_hours';
  end if;

  select to_jsonb(r) into v_before
    from public.loyalty_programs r where r.business_id = p_business_id;

  insert into public.loyalty_programs (
    business_id, cop_per_point_unit, points_per_cop_unit, points_expiry_days,
    budget_rate, first_purchase_bonus_points, recurrence_bonus_points,
    referral_bonus_points, qr_expiry_hours, is_active, configured_by, configured_at
  ) values (
    p_business_id, p_cop_per_point_unit, p_points_per_cop_unit, p_points_expiry_days,
    p_budget_rate, p_first_purchase_bonus_points, p_recurrence_bonus_points,
    p_referral_bonus_points, p_qr_expiry_hours, p_is_active, v_uid, now()
  )
  on conflict (business_id) do update
    set cop_per_point_unit = excluded.cop_per_point_unit,
        points_per_cop_unit = excluded.points_per_cop_unit,
        points_expiry_days = excluded.points_expiry_days,
        budget_rate = excluded.budget_rate,
        first_purchase_bonus_points = excluded.first_purchase_bonus_points,
        recurrence_bonus_points = excluded.recurrence_bonus_points,
        referral_bonus_points = excluded.referral_bonus_points,
        qr_expiry_hours = excluded.qr_expiry_hours,
        is_active = excluded.is_active,
        configured_by = excluded.configured_by,
        configured_at = excluded.configured_at,
        updated_at = now()
  returning id into v_id;

  select to_jsonb(r) into v_after
    from public.loyalty_programs r where r.id = v_id;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'loyalty_program.configured',
    'loyalty_program',
    v_id::text,
    jsonb_build_object('before', v_before, 'after', v_after)
  );

  return jsonb_build_object(
    'program_id', v_id,
    'business_id', p_business_id,
    'is_active', p_is_active,
    'configured_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Crear miembros: roles permitidos y cuenta de puntos
-- ---------------------------------------------------------------------
create or replace function public.business_membership_create(
  p_business_id uuid,
  p_user_id uuid,
  p_role public.business_role default 'encargado',
  p_can_approve_redemptions boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_membership_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  perform public.require_business_role(p_business_id, array['admin']);

  -- Solo el creador del negocio puede nombrar a otro administrador.
  if p_role = 'admin' then
    if not exists (
      select 1 from public.businesses
       where id = p_business_id and created_by = v_uid
    ) then
      raise exception 'invalid_role';
    end if;
  elsif p_role not in ('encargado', 'cliente') then
    raise exception 'invalid_role';
  end if;

  if p_role <> 'admin' and p_can_approve_redemptions and p_role <> 'encargado' then
    raise exception 'invalid_approval_permission';
  end if;

  -- No dejar el negocio sin administrador.
  if p_role <> 'admin'
     and exists (
       select 1 from public.business_memberships
        where business_id = p_business_id and user_id = p_user_id and role = 'admin'
     )
     and (select count(*) from public.business_memberships
           where business_id = p_business_id and role = 'admin') <= 1 then
    raise exception 'last_admin';
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'user_not_found';
  end if;

  insert into public.business_memberships (
    business_id, user_id, role, can_approve_redemptions, created_by
  ) values (
    p_business_id, p_user_id, p_role, p_can_approve_redemptions, v_uid
  )
  on conflict (business_id, user_id) do update
    set role = excluded.role,
        can_approve_redemptions = excluded.can_approve_redemptions,
        updated_at = now()
  returning id into v_membership_id;

  -- Toda membresía tiene cuenta de puntos (aunque sea con saldo 0).
  insert into public.loyalty_point_accounts (business_id, customer_id)
  values (p_business_id, p_user_id)
  on conflict (business_id, customer_id) do nothing;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    case when p_role = 'admin' then 'membership.admin' else 'membership.created' end,
    'business_membership',
    v_membership_id::text,
    jsonb_build_object('user_id', p_user_id, 'role', p_role, 'can_approve_redemptions', p_can_approve_redemptions)
  );

  return jsonb_build_object(
    'membership_id', v_membership_id,
    'user_id', p_user_id,
    'role', p_role,
    'can_approve_redemptions', p_can_approve_redemptions
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Búsqueda de perfiles por negocio (solo admin del negocio)
-- ---------------------------------------------------------------------
create or replace function public.business_search_profiles(
  p_business_id uuid,
  p_query text default ''
)
returns table (
  user_id uuid,
  full_name text,
  email text,
  already_member boolean
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
  perform public.require_business_role(p_business_id, array['admin']);

  v_query := replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_');

  return query
    select p.id, p.full_name, p.email, (m.user_id is not null)
      from public.profiles p
      left join public.business_memberships m
        on m.business_id = p_business_id and m.user_id = p.id
     where v_query = ''
        or p.email ilike '%' || v_query || '%'
        or p.full_name ilike '%' || v_query || '%'
     order by p.full_name, p.email
     limit 25;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Ficha pública del negocio y afiliación de clientes
-- ---------------------------------------------------------------------
create or replace function public.business_public_get(
  p_slug text
)
returns table (
  id uuid,
  name text,
  slug text,
  timezone text,
  operating_days smallint[],
  is_active boolean,
  loyalty_active boolean
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select b.id, b.name, b.slug, b.timezone, b.operating_days, b.is_active,
         coalesce(p.is_active, false)
    from public.businesses b
    left join public.loyalty_programs p on p.business_id = b.id
   where b.slug = lower(btrim(p_slug))
     and b.is_active
   limit 1;
$$;

create or replace function public.business_join(
  p_slug text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_business public.businesses;
  v_membership_id uuid;
  v_role public.business_role;
  v_joined boolean := false;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select b.* into v_business
    from public.businesses b
   where b.slug = lower(btrim(p_slug))
     and b.is_active;

  if not found then
    raise exception 'business_not_found';
  end if;

  insert into public.business_memberships (business_id, user_id, role, created_by)
  values (v_business.id, v_uid, 'cliente', v_uid)
  on conflict (business_id, user_id) do nothing
  returning id into v_membership_id;

  v_joined := v_membership_id is not null;

  if v_joined then
    v_role := 'cliente';
  else
    select m.id, m.role into v_membership_id, v_role
      from public.business_memberships m
     where m.business_id = v_business.id and m.user_id = v_uid;
  end if;

  -- Cuenta de puntos lista desde la afiliación.
  insert into public.loyalty_point_accounts (business_id, customer_id)
  values (v_business.id, v_uid)
  on conflict (business_id, customer_id) do nothing;

  if v_joined then
    insert into public.business_audit_logs (
      business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
    ) values (
      v_business.id,
      v_uid,
      (select email from public.profiles where id = v_uid),
      'membership.joined',
      'business_membership',
      v_membership_id::text,
      jsonb_build_object('slug', v_business.slug, 'role', 'cliente')
    );
  end if;

  return jsonb_build_object(
    'business_id', v_business.id,
    'business_name', v_business.name,
    'slug', v_business.slug,
    'membership_id', v_membership_id,
    'role', v_role,
    'already_member', not v_joined
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Redenciones del propio cliente (incluye nombre del negocio)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_my_redemptions(
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  id uuid,
  business_id uuid,
  business_name text,
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
    select r.id, r.business_id, b.name, r.reward_name, r.reward_type,
           r.points_spent, r.code, r.status, r.created_at,
           r.approved_at, r.delivered_at, r.cancelled_at
      from public.loyalty_redemptions r
      join public.loyalty_point_accounts a on a.id = r.account_id
      join public.businesses b on b.id = r.business_id
     where a.customer_id = v_uid
     order by r.created_at desc
     limit v_limit offset v_offset;
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Reemitir token QR (solo el dueño y solo si sigue pendiente)
-- ---------------------------------------------------------------------
create or replace function public.redemption_token_reissue(
  p_redemption_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_redemption public.loyalty_redemptions;
  v_customer_id uuid;
  v_program public.loyalty_programs;
  v_token text;
  v_token_hash text;
  v_expires_at timestamptz;
  v_recent integer;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_redemption
    from public.loyalty_redemptions
   where id = p_redemption_id
   for update;

  if not found then raise exception 'redemption_not_found'; end if;

  select a.customer_id into v_customer_id
    from public.loyalty_point_accounts a
   where a.id = v_redemption.account_id;

  if v_customer_id <> v_uid then
    raise exception 'forbidden';
  end if;

  if v_redemption.status <> 'pending' then
    raise exception 'redemption_not_reissuable';
  end if;

  select count(*)::integer into v_recent
    from public.loyalty_redemption_tokens
   where redemption_id = p_redemption_id
     and created_at > now() - interval '1 hour';

  if v_recent >= 10 then
    raise exception 'token_reissue_limit';
  end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = v_redemption.business_id;

  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  v_expires_at := now() + make_interval(hours => coalesce(v_program.qr_expiry_hours, 24));

  -- Rotación: los tokens no consumidos anteriores dejan de ser válidos.
  delete from public.loyalty_redemption_tokens
   where redemption_id = p_redemption_id
     and consumed_at is null;

  insert into public.loyalty_redemption_tokens (
    business_id, redemption_id, token_hash, expires_at
  ) values (
    v_redemption.business_id, p_redemption_id, v_token_hash, v_expires_at
  );

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    v_redemption.business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.token_reissued',
    'loyalty_redemption',
    p_redemption_id::text,
    jsonb_build_object('expires_at', v_expires_at)
  );

  return jsonb_build_object(
    'redemption_id', p_redemption_id,
    'token', v_token,
    'expires_at', v_expires_at
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Libro de movimientos: firma con el orden usado por los llamadores
--     (negocio, cuenta, tipo, puntos, referencia, id, motivo, clave, autor)
-- ---------------------------------------------------------------------
drop function if exists public.loyalty_transaction_post(
  uuid, uuid, public.point_movement_type, integer, text, uuid, text, uuid, text
);

create or replace function public.loyalty_transaction_post(
  p_business_id uuid,
  p_account_id uuid,
  p_movement_type public.point_movement_type,
  p_points integer,
  p_reference_type text,
  p_reference_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_created_by uuid
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
begin
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception 'invalid_idempotency_key';
  end if;

  -- Idempotencia: si ya existe el movimiento, devolverlo sin duplicar.
  select * into v_tx
    from public.loyalty_point_transactions
   where idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_tx.business_id <> p_business_id or v_tx.account_id <> p_account_id then
      raise exception 'idempotency_key_conflict';
    end if;
    return v_tx;
  end if;

  select * into v_account
    from public.loyalty_point_accounts
   where id = p_account_id and business_id = p_business_id
   for update;

  if not found then
    raise exception 'account_not_found';
  end if;

  insert into public.loyalty_point_transactions (
    business_id, account_id, movement_type, points,
    reference_type, reference_id, reason, idempotency_key, created_by
  ) values (
    p_business_id, p_account_id, p_movement_type, p_points,
    p_reference_type, p_reference_id, p_reason, p_idempotency_key, p_created_by
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
-- 13. Asegurar cuenta con autorización (propia o staff del negocio)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_account_ensure(
  p_business_id uuid,
  p_customer_id uuid
)
returns public.loyalty_point_accounts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_account public.loyalty_point_accounts;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  if v_uid <> p_customer_id and not exists (
    select 1 from public.business_memberships
     where business_id = p_business_id
       and user_id = v_uid
       and role in ('admin', 'encargado')
  ) then
    raise exception 'forbidden';
  end if;

  select * into v_account
    from public.loyalty_point_accounts
   where business_id = p_business_id
     and customer_id = p_customer_id;

  if not found then
    insert into public.loyalty_point_accounts (business_id, customer_id, balance)
    values (p_business_id, p_customer_id, 0)
    returning * into v_account;
  end if;

  return v_account;
end;
$$;

-- ---------------------------------------------------------------------
-- 14. Acumular puntos de una compra (idempotente y autorizado)
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
  v_account public.loyalty_point_accounts;
  v_points integer;
  v_tx public.loyalty_point_transactions;
  v_balance bigint;
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
    select coalesce(sum(points), 0) into v_balance
      from public.loyalty_point_transactions
     where account_id = p_account_id;
    return jsonb_build_object(
      'points_earned', 0,
      'balance', v_balance,
      'duplicate', true,
      'message', 'La compra ya fue procesada.'
    );
  end if;

  -- Evitar duplicar puntos al reprocesar una misma compra.
  if p_purchase_id is not null then
    if exists (
      select 1 from public.loyalty_purchase_events where purchase_id = p_purchase_id
    ) then
      select coalesce(sum(points), 0) into v_balance
        from public.loyalty_point_transactions
       where account_id = p_account_id;
      return jsonb_build_object(
        'points_earned', 0,
        'balance', v_balance,
        'duplicate', true,
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

  v_points := floor(p_eligible_amount_cop::numeric / v_program.cop_per_point_unit)::integer;
  v_points := least(v_points, 1000000);

  if v_points > 0 then
    perform public.loyalty_transaction_post(
      p_business_id, p_account_id, 'purchase_credit', v_points,
      'purchase', p_purchase_id,
      format('Compra %s COP elegibles %s COP (regla %s)',
             p_amount_cop, p_eligible_amount_cop, coalesce(p_rule_version, 'inicial')),
      p_idempotency_key, v_uid
    );
  end if;

  insert into public.loyalty_purchase_events (
    business_id, account_id, purchase_id, amount_cop,
    eligible_amount_cop, points_earned, rule_version
  ) values (
    p_business_id, p_account_id, p_purchase_id, p_amount_cop,
    p_eligible_amount_cop, v_points, coalesce(p_rule_version, 'v1')
  );

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  return jsonb_build_object(
    'points_earned', v_points,
    'balance', v_balance,
    'duplicate', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 15. Reversar puntos de una compra (idempotente y autorizado)
-- ---------------------------------------------------------------------
create or replace function public.points_reverse_purchase(
  p_business_id uuid,
  p_account_id uuid,
  p_purchase_id uuid,
  p_reason text,
  p_created_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_account public.loyalty_point_accounts;
  v_event public.loyalty_purchase_events;
  v_balance bigint;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  select * into v_account
    from public.loyalty_point_accounts
   where id = p_account_id and business_id = p_business_id;

  if not found then raise exception 'account_not_found'; end if;

  select * into v_event
    from public.loyalty_purchase_events
   where purchase_id = p_purchase_id and business_id = p_business_id
   for update;

  if not found then
    raise exception 'purchase_event_not_found';
  end if;

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  if v_event.points_earned <= 0 then
    return jsonb_build_object('points_reversed', 0, 'balance', v_balance, 'duplicate', false);
  end if;

  -- Idempotencia: evitar doble devolución.
  if exists (
    select 1 from public.loyalty_point_transactions
     where account_id = p_account_id
       and movement_type = 'redemption_refund'
       and reference_type = 'purchase'
       and reference_id = p_purchase_id
  ) then
    return jsonb_build_object(
      'points_reversed', 0,
      'balance', v_balance,
      'duplicate', true,
      'message', 'La compra ya fue revertida.'
    );
  end if;

  perform public.loyalty_transaction_post(
    p_business_id, p_account_id, 'redemption_refund', -v_event.points_earned,
    'purchase', p_purchase_id,
    p_reason,
    'purchase:' || p_purchase_id::text || ':reverse', v_uid
  );

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  return jsonb_build_object(
    'points_reversed', v_event.points_earned,
    'balance', v_balance,
    'duplicate', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 16. Bonos configurables (solo admin del negocio)
-- ---------------------------------------------------------------------
create or replace function public.points_grant_bonus(
  p_business_id uuid,
  p_account_id uuid,
  p_bonus_type text,
  p_points integer,
  p_reason text,
  p_idempotency_key text,
  p_created_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_account public.loyalty_point_accounts;
  v_program public.loyalty_programs;
  v_points integer := greatest(coalesce(p_points, 0), 0);
  v_balance bigint;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  select * into v_account
    from public.loyalty_point_accounts
   where id = p_account_id and business_id = p_business_id;

  if not found then raise exception 'account_not_found'; end if;

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  if v_points <= 0 then
    return jsonb_build_object('points_granted', 0, 'skipped', true, 'balance', v_balance);
  end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found or not v_program.is_active then
    raise exception 'program_not_active';
  end if;

  perform public.loyalty_transaction_post(
    p_business_id, p_account_id, 'bonus_credit', v_points,
    'bonus', null, p_reason, p_idempotency_key, v_uid
  );

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = p_account_id;

  return jsonb_build_object(
    'points_granted', v_points,
    'balance', v_balance,
    'skipped', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 17. Registrar compra desde el panel (wrapper seguro)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_purchase_register(
  p_business_id uuid,
  p_customer_id uuid,
  p_amount_cop integer,
  p_eligible_amount_cop integer,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_account_id uuid;
  v_result jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  if p_customer_id is null then raise exception 'invalid_customer'; end if;
  if not exists (
    select 1 from public.business_memberships
     where business_id = p_business_id and user_id = p_customer_id
  ) then
    raise exception 'customer_not_member';
  end if;

  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,64}$' then
    raise exception 'invalid_idempotency_key';
  end if;

  insert into public.loyalty_point_accounts (business_id, customer_id)
  values (p_business_id, p_customer_id)
  on conflict (business_id, customer_id) do nothing;

  select id into v_account_id
    from public.loyalty_point_accounts
   where business_id = p_business_id and customer_id = p_customer_id;

  v_result := public.points_accrue_from_purchase(
    p_business_id,
    v_account_id,
    null,
    p_amount_cop,
    p_eligible_amount_cop,
    'purchase:' || p_business_id::text || ':' || p_idempotency_key,
    v_uid,
    'v1'
  );

  return v_result || jsonb_build_object('account_id', v_account_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 18. Recompensas disponibles: un cliente solo consulta las suyas
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
  v_customer_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  v_membership := public.business_current_membership(p_business_id);

  -- Solo el admin puede consultar el saldo de otro cliente del negocio.
  v_customer_id := case
    when v_membership.role = 'admin' then p_customer_id
    else v_uid
  end;

  select coalesce(balance, 0) into v_balance
    from public.loyalty_point_accounts
   where business_id = p_business_id and customer_id = v_customer_id;

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

-- ---------------------------------------------------------------------
-- 19. Validación de token QR: devolver customer_id real (no account_id)
-- ---------------------------------------------------------------------
create or replace function public.redemption_token_validate(
  p_business_id uuid,
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_token_hash text;
  v_token public.loyalty_redemption_tokens;
  v_redemption public.loyalty_redemptions;
  v_membership public.business_memberships;
  v_customer_id uuid;
  v_now timestamptz := now();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  v_token_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');

  select * into v_token
    from public.loyalty_redemption_tokens
   where token_hash = v_token_hash
   for update;

  if not found then
    raise exception 'invalid_token';
  end if;

  if v_token.business_id <> p_business_id then
    raise exception 'forbidden';
  end if;

  v_membership := public.business_current_membership(p_business_id);
  if v_membership.role <> 'admin' and v_membership.role <> 'encargado' then
    raise exception 'forbidden';
  end if;
  if v_membership.role = 'encargado' and not v_membership.can_approve_redemptions then
    raise exception 'forbidden';
  end if;

  select * into v_redemption
    from public.loyalty_redemptions
   where id = v_token.redemption_id
   for update;

  if not found then
    raise exception 'redemption_not_found';
  end if;

  if v_redemption.business_id <> p_business_id then
    raise exception 'forbidden';
  end if;

  if v_redemption.status <> 'pending' then
    raise exception 'redemption_not_pending';
  end if;

  if v_token.consumed_at is not null then
    raise exception 'token_already_consumed';
  end if;

  if v_token.expires_at <= v_now then
    raise exception 'token_expired';
  end if;

  select a.customer_id into v_customer_id
    from public.loyalty_point_accounts a
   where a.id = v_redemption.account_id;

  return jsonb_build_object(
    'redemption_id', v_redemption.id,
    'reward_name', v_redemption.reward_name,
    'reward_type', v_redemption.reward_type,
    'points_spent', v_redemption.points_spent,
    'status', v_redemption.status,
    'customer_id', v_customer_id,
    'expires_at', v_token.expires_at,
    'can_approve', true
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 20. RLS: evitar recursión infinita en las políticas que consultan
--     business_memberships desde business_memberships/businesses.
--     El helper es SECURITY DEFINER y no vuelve a aplicar RLS.
-- ---------------------------------------------------------------------
create or replace function public.is_business_member(
  p_business_id uuid,
  p_roles text[] default null
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.business_memberships m
     where m.business_id = p_business_id
       and m.user_id = auth.uid()
       and (p_roles is null or m.role::text = any (p_roles))
  );
$$;

drop policy if exists businesses_select_member on public.businesses;
create policy businesses_select_member
  on public.businesses for select to authenticated
  using (public.is_business_member(id));

drop policy if exists business_memberships_select_own_or_staff on public.business_memberships;
create policy business_memberships_select_own_or_staff
  on public.business_memberships for select to authenticated
  using (
    user_id = auth.uid()
    or public.is_business_member(business_id, array['admin', 'encargado'])
  );

-- ---------------------------------------------------------------------
-- 21. Backfill: programas y perfiles económicos para negocios existentes
-- ---------------------------------------------------------------------
insert into public.loyalty_programs (business_id)
select b.id
  from public.businesses b
  left join public.loyalty_programs p on p.business_id = b.id
 where p.business_id is null
on conflict (business_id) do nothing;

insert into public.business_economic_profiles (business_id)
select b.id
  from public.businesses b
  left join public.business_economic_profiles e on e.business_id = b.id
 where e.business_id is null
on conflict (business_id) do nothing;

-- ---------------------------------------------------------------------
-- 22. Grants
-- ---------------------------------------------------------------------
grant execute on function public.require_business_role(uuid, text[]) to authenticated;
grant execute on function public.is_business_member(uuid, text[]) to authenticated;
grant execute on function public.get_my_app_roles() to authenticated;
grant execute on function public.business_register(text, text, text) to authenticated;
grant execute on function public.businesses_list() to authenticated;
grant execute on function public.loyalty_program_get(uuid) to authenticated;
grant execute on function public.loyalty_program_configure(
  uuid, integer, integer, integer, numeric, integer, integer, integer, integer, boolean
) to authenticated;
grant execute on function public.business_membership_create(
  uuid, uuid, public.business_role, boolean
) to authenticated;
grant execute on function public.business_search_profiles(uuid, text) to authenticated;
grant execute on function public.business_public_get(text) to anon, authenticated;
grant execute on function public.business_join(text) to authenticated;
grant execute on function public.loyalty_my_redemptions(integer, integer) to authenticated;
grant execute on function public.redemption_token_reissue(uuid) to authenticated;
grant execute on function public.points_accrue_from_purchase(
  uuid, uuid, uuid, integer, integer, text, uuid, text
) to authenticated;
grant execute on function public.points_reverse_purchase(uuid, uuid, uuid, text, uuid) to authenticated;
grant execute on function public.points_grant_bonus(
  uuid, uuid, text, integer, text, text, uuid
) to authenticated;
grant execute on function public.loyalty_purchase_register(
  uuid, uuid, integer, integer, text
) to authenticated;
grant execute on function public.loyalty_account_ensure(uuid, uuid) to authenticated;
grant execute on function public.loyalty_rewards_available(uuid, uuid) to authenticated;

-- `loyalty_transaction_post` es interno: solo lo usan funciones SECURITY DEFINER.
revoke execute on function public.loyalty_transaction_post(
  uuid, uuid, public.point_movement_type, integer, text, uuid, text, text, uuid
) from authenticated;
revoke execute on function public.loyalty_transaction_post(
  uuid, uuid, public.point_movement_type, integer, text, uuid, text, text, uuid
) from anon;

-- ---------------------------------------------------------------------
-- 23. Comprobaciones rápidas (fallan si algo quedó mal)
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_proc
     where proname = 'require_business_role'
       and 'text[]'::regtype = any (proargtypes::regtype[])
  ) then
    raise exception 'require_business_role(uuid, text[]) no existe';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'loyalty_redemptions'
       and column_name = 'cancelled_by'
  ) then
    raise exception 'loyalty_redemptions.cancelled_by no existe';
  end if;
end
$$;
