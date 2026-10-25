-- =====================================================================
-- Funciones de negocio: aislamiento por negocio y fidelización por puntos
-- Todas las operaciones sensibles son SECURITY DEFINER con search_path fijo
-- y autorización en PostgreSQL. El negocio se obtiene y valida en el
-- servidor a partir de auth.uid(); nunca se confía en el negocio enviado
-- por el navegador.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Utilidades de autorización por negocio
-- ---------------------------------------------------------------------
create or replace function public.business_current_membership(
  p_business_id uuid
)
returns public.business_memberships
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_membership public.business_memberships;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_membership
    from public.business_memberships
   where business_id = p_business_id
     and user_id = v_uid;

  if not found then
    raise exception 'business_not_found_or_no_access';
  end if;

  return v_membership;
end;
$$;

create or replace function public.require_business_role(
  p_business_id uuid,
  p_allowed public.business_role[]
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

  if not (v_membership.role = any(p_allowed)) then
    raise exception 'forbidden';
  end if;

  return v_membership;
end;
$$;

-- ---------------------------------------------------------------------
-- Registro de negocio y administrador (transaccional)
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
-- Membresías: crear encargado (solo admin del negocio)
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

  if p_role not in ('admin', 'encargado', 'cliente') then
    raise exception 'invalid_role';
  end if;
  if p_role = 'admin' and p_can_approve_redemptions then
    raise exception 'invalid_approval_permission';
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
-- Actualizar permiso de encargado (solo admin del negocio)
-- ---------------------------------------------------------------------
create or replace function public.business_membership_update(
  p_business_id uuid,
  p_user_id uuid,
  p_can_approve_redemptions boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  perform public.require_business_role(p_business_id, array['admin']);

  update public.business_memberships
     set can_approve_redemptions = p_can_approve_redemptions,
         updated_at = now()
   where business_id = p_business_id
     and user_id = p_user_id
     and role <> 'admin';

  if not found then
    raise exception 'membership_not_found';
  end if;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'membership.permission_updated',
    'business_membership',
    p_user_id::text,
    jsonb_build_object('user_id', p_user_id, 'can_approve_redemptions', p_can_approve_redemptions)
  );

  return jsonb_build_object(
    'user_id', p_user_id,
    'can_approve_redemptions', p_can_approve_redemptions
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Listar miembros del negocio (admin/encargado del negocio)
-- ---------------------------------------------------------------------
create or replace function public.business_memberships_list(
  p_business_id uuid
)
returns table (
  id uuid,
  user_id uuid,
  full_name text,
  email text,
  role public.business_role,
  can_approve_redemptions boolean,
  created_at timestamptz
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
    select m.id, m.user_id, p.full_name, p.email, m.role,
           m.can_approve_redemptions, m.created_at
      from public.business_memberships m
      join public.profiles p on p.id = m.user_id
     where m.business_id = p_business_id
     order by m.role, p.full_name;
end;
$$;

-- ---------------------------------------------------------------------
-- Configurar programa de puntos (solo admin del negocio)
-- ---------------------------------------------------------------------
create or replace function public.loyalty_program_configure(
  p_business_id uuid,
  p_cop_per_point_unit integer,
  p_points_per_cop_unit integer,
  p_points_expiry_days integer,
  p_budget_rate numeric,
  p_first_purchase_bonus_points integer,
  p_recurrence_bonus_points integer,
  p_referral_bonus_points integer,
  p_qr_expiry_hours integer
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
    p_referral_bonus_points, p_qr_expiry_hours, true, v_uid, now()
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
        is_active = true,
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
    'is_active', true,
    'configured_at', now()
  );
end;
$$;
