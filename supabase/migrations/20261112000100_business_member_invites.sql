-- =====================================================================
-- Invitaciones por QR para añadir o promover miembros en un negocio
--
--   1. Tabla `public.business_member_invites`: almacena hash SHA-256 del
--      token, rol destino ('encargado' o 'cliente'), permiso de aprobación
--      y expiración (uso único).
--   2. `public.business_member_invite_create(...)`: solo admin del negocio.
--   3. `public.business_member_invite_preview(p_token)`: vista pública
--      (anon + authenticated) sin exponer PII ni hashes.
--   4. `public.business_member_invite_accept(p_token)`: usuario autenticado
--      acepta la invitación; crea la membresía o cambia el rol si ya estaba
--      registrado como cliente (nunca degrada a un admin ni a un encargado).
--   5. `public.business_member_invite_revoke(p_business_id, p_invite_id)`:
--      anula una invitación pendiente (solo admin del negocio).
-- =====================================================================

create table if not exists public.business_member_invites (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  role public.business_role not null,
  can_approve_redemptions boolean not null default false,
  token_hash text not null,
  created_by uuid references public.profiles(id) on delete set null,
  expires_at timestamptz not null,
  accepted_by uuid references public.profiles(id) on delete set null,
  accepted_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint business_member_invites_role_check
    check (role in ('encargado', 'cliente')),
  constraint business_member_invites_approval_check
    check (role = 'encargado' or not can_approve_redemptions),
  constraint business_member_invites_token_hash_format
    check (token_hash ~ '^[a-f0-9]{64}$'),
  constraint business_member_invites_token_hash_unique
    unique (token_hash)
);

create index if not exists business_member_invites_business_idx
  on public.business_member_invites (business_id, created_at desc);

comment on table public.business_member_invites is
  'Invitaciones de uso único con QR para incorporar o cambiar de rol a un miembro del negocio.';

alter table public.business_member_invites enable row level security;

drop policy if exists business_member_invites_select_admin on public.business_member_invites;
create policy business_member_invites_select_admin
  on public.business_member_invites for select to authenticated
  using (
    exists (
      select 1
        from public.business_memberships m
       where m.business_id = business_member_invites.business_id
         and m.user_id = auth.uid()
         and m.role = 'admin'
    )
  );

revoke all on public.business_member_invites from public, anon, authenticated;
grant select (
  id,
  business_id,
  role,
  can_approve_redemptions,
  created_by,
  expires_at,
  accepted_by,
  accepted_at,
  revoked_at,
  created_at
) on public.business_member_invites to authenticated;
grant all on public.business_member_invites to service_role;

-- ---------------------------------------------------------------------
-- 1. Crear invitación QR (solo administrador del negocio)
-- ---------------------------------------------------------------------
create or replace function public.business_member_invite_create(
  p_business_id uuid,
  p_role public.business_role default 'encargado',
  p_can_approve_redemptions boolean default false,
  p_expires_hours integer default 24
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_business public.businesses;
  v_can_approve boolean := coalesce(p_can_approve_redemptions, false);
  v_token text;
  v_invite_id uuid;
  v_expires_at timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  perform public.require_business_role(p_business_id, array['admin']);

  if p_role is null or p_role not in ('encargado', 'cliente') then
    raise exception 'invalid_role';
  end if;

  if p_role <> 'encargado' and v_can_approve then
    raise exception 'invalid_approval_permission';
  end if;

  if p_expires_hours is null or p_expires_hours < 1 or p_expires_hours > 168 then
    raise exception 'invalid_invite_expiry';
  end if;

  select * into v_business
    from public.businesses
   where id = p_business_id
     and is_active;

  if not found then
    raise exception 'business_not_found';
  end if;

  perform private.consume_rate_limit('business_member_invite_create:' || v_uid::text, 30, 60);

  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_expires_at := now() + make_interval(hours => p_expires_hours);

  insert into public.business_member_invites (
    business_id,
    role,
    can_approve_redemptions,
    token_hash,
    created_by,
    expires_at
  ) values (
    p_business_id,
    p_role,
    v_can_approve,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    v_uid,
    v_expires_at
  )
  returning id into v_invite_id;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'membership.invite_created',
    'business_member_invite',
    v_invite_id::text,
    jsonb_build_object(
      'role', p_role,
      'can_approve_redemptions', v_can_approve,
      'expires_at', v_expires_at
    )
  );

  return jsonb_build_object(
    'invite_id', v_invite_id,
    'token', v_token,
    'business_id', v_business.id,
    'business_name', v_business.name,
    'business_slug', v_business.slug,
    'role', p_role,
    'can_approve_redemptions', v_can_approve,
    'expires_at', v_expires_at
  );
end;
$$;

revoke execute on function public.business_member_invite_create(uuid, public.business_role, boolean, integer) from public, anon;
grant execute on function public.business_member_invite_create(uuid, public.business_role, boolean, integer) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. Vista pública previa del QR de invitación (anon + authenticated)
-- ---------------------------------------------------------------------
create or replace function public.business_member_invite_preview(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_invite public.business_member_invites;
  v_business public.businesses;
  v_status text;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  perform private.consume_rate_limit('business_member_invite_preview:global', 300, 60);
  perform private.consume_rate_limit(
    'business_member_invite_preview:' || left(encode(extensions.digest(p_token, 'sha256'), 'hex'), 24),
    60, 60
  );

  select * into v_invite
    from public.business_member_invites
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');

  if not found then
    raise exception 'invalid_token';
  end if;

  select * into v_business
    from public.businesses
   where id = v_invite.business_id
     and is_active;

  if not found then
    raise exception 'business_not_found';
  end if;

  if v_invite.revoked_at is not null then
    v_status := 'revoked';
  elsif v_invite.accepted_at is not null then
    v_status := 'accepted';
  elsif v_invite.expires_at <= now() then
    v_status := 'expired';
  else
    v_status := 'pending';
  end if;

  return jsonb_build_object(
    'invite_id', v_invite.id,
    'business_id', v_business.id,
    'business_name', v_business.name,
    'business_slug', v_business.slug,
    'role', v_invite.role,
    'can_approve_redemptions', v_invite.can_approve_redemptions,
    'status', v_status,
    'expires_at', v_invite.expires_at
  );
end;
$$;

revoke execute on function public.business_member_invite_preview(text) from public;
grant execute on function public.business_member_invite_preview(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. Aceptar invitación QR (crea membresía o cambia rol si era cliente)
-- ---------------------------------------------------------------------
create or replace function public.business_member_invite_accept(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := now();
  v_invite public.business_member_invites;
  v_business public.businesses;
  v_existing_membership_id uuid;
  v_previous_role public.business_role;
  v_previous_can_approve boolean := false;
  v_membership_id uuid;
  v_effective_role public.business_role;
  v_effective_can_approve boolean := false;
  v_role_changed boolean := false;
  v_permission_changed boolean := false;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  perform private.consume_rate_limit('business_member_invite_accept:' || v_uid::text, 20, 60);

  select * into v_invite
    from public.business_member_invites
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
   for update;

  if not found then
    raise exception 'invalid_token';
  end if;

  if v_invite.revoked_at is not null then
    raise exception 'invite_revoked';
  end if;

  select * into v_business
    from public.businesses
   where id = v_invite.business_id
     and is_active;

  if not found then
    raise exception 'business_not_found';
  end if;

  if v_invite.accepted_at is not null then
    if v_invite.accepted_by = v_uid then
      select m.id, m.role, m.can_approve_redemptions
        into v_membership_id, v_previous_role, v_effective_can_approve
        from public.business_memberships m
       where m.business_id = v_invite.business_id
         and m.user_id = v_uid;

      return jsonb_build_object(
        'invite_id', v_invite.id,
        'business_id', v_business.id,
        'business_name', v_business.name,
        'business_slug', v_business.slug,
        'membership_id', v_membership_id,
        'role', coalesce(v_previous_role, v_invite.role),
        'can_approve_redemptions', coalesce(v_effective_can_approve, v_invite.can_approve_redemptions),
        'previous_role', v_previous_role,
        'role_changed', false,
        'already_accepted', true
      );
    end if;
    raise exception 'invite_already_used';
  end if;

  if v_invite.expires_at <= v_now then
    raise exception 'invite_expired';
  end if;

  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'user_not_found';
  end if;

  select m.id, m.role, m.can_approve_redemptions
    into v_existing_membership_id, v_previous_role, v_previous_can_approve
    from public.business_memberships m
   where m.business_id = v_invite.business_id
     and m.user_id = v_uid
   for update;

  if v_previous_role = 'admin' then
    raise exception 'invite_already_admin';
  end if;

  if v_previous_role = 'encargado' and v_invite.role = 'cliente' then
    raise exception 'invite_role_downgrade';
  end if;

  v_effective_can_approve :=
    case
      when v_invite.role = 'encargado' then
        coalesce(v_previous_can_approve, false) or v_invite.can_approve_redemptions
      else false
    end;

  insert into public.business_memberships (
    business_id, user_id, role, can_approve_redemptions, created_by
  ) values (
    v_invite.business_id, v_uid, v_invite.role, v_effective_can_approve, v_invite.created_by
  )
  on conflict (business_id, user_id) do update
    set role = excluded.role,
        can_approve_redemptions = excluded.can_approve_redemptions,
        updated_at = v_now
    where public.business_memberships.role <> 'admin'
  returning id, role, can_approve_redemptions
    into v_membership_id, v_effective_role, v_effective_can_approve;

  if v_membership_id is null then
    raise exception 'invite_already_admin';
  end if;

  insert into public.loyalty_point_accounts (business_id, customer_id)
  values (v_invite.business_id, v_uid)
  on conflict (business_id, customer_id) do nothing;

  update public.business_member_invites
     set accepted_by = v_uid,
         accepted_at = v_now
   where id = v_invite.id;

  v_role_changed := v_previous_role is not null and v_previous_role <> v_effective_role;
  v_permission_changed := v_previous_role is not null
    and not v_role_changed
    and coalesce(v_previous_can_approve, false) is distinct from v_effective_can_approve;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    v_invite.business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    case
      when v_role_changed then 'membership.role_updated'
      when v_previous_role is null then 'membership.created'
      when v_permission_changed then 'membership.permission_updated'
      else 'membership.invite_accepted'
    end,
    'business_membership',
    v_membership_id::text,
    jsonb_build_object(
      'invite_id', v_invite.id,
      'invited_by', v_invite.created_by,
      'user_id', v_uid,
      'role', v_effective_role,
      'previous_role', v_previous_role,
      'can_approve_redemptions', v_effective_can_approve,
      'source', 'invite_qr'
    )
  );

  return jsonb_build_object(
    'invite_id', v_invite.id,
    'business_id', v_business.id,
    'business_name', v_business.name,
    'business_slug', v_business.slug,
    'membership_id', v_membership_id,
    'role', v_effective_role,
    'can_approve_redemptions', v_effective_can_approve,
    'previous_role', v_previous_role,
    'role_changed', v_role_changed,
    'already_accepted', false
  );
end;
$$;

revoke execute on function public.business_member_invite_accept(text) from public, anon;
grant execute on function public.business_member_invite_accept(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. Revocar invitación QR pendiente (solo administrador del negocio)
-- ---------------------------------------------------------------------
create or replace function public.business_member_invite_revoke(
  p_business_id uuid,
  p_invite_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := now();
  v_invite public.business_member_invites;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  perform public.require_business_role(p_business_id, array['admin']);

  select * into v_invite
    from public.business_member_invites
   where id = p_invite_id
     and business_id = p_business_id
   for update;

  if not found then
    raise exception 'invite_not_found';
  end if;

  if v_invite.accepted_at is not null then
    raise exception 'invite_already_used';
  end if;

  if v_invite.revoked_at is null then
    update public.business_member_invites
       set revoked_at = v_now
     where id = v_invite.id
     returning * into v_invite;

    insert into public.business_audit_logs (
      business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
    ) values (
      p_business_id,
      v_uid,
      (select email from public.profiles where id = v_uid),
      'membership.invite_revoked',
      'business_member_invite',
      v_invite.id::text,
      jsonb_build_object(
        'invite_id', v_invite.id,
        'role', v_invite.role
      )
    );
  end if;

  return jsonb_build_object(
    'invite_id', v_invite.id,
    'business_id', v_invite.business_id,
    'revoked_at', v_invite.revoked_at
  );
end;
$$;

revoke execute on function public.business_member_invite_revoke(uuid, uuid) from public, anon;
grant execute on function public.business_member_invite_revoke(uuid, uuid) to authenticated, service_role;
