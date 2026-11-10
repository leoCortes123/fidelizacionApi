-- =====================================================================
-- Registro de usuarios con selección de tipo de cuenta (cliente / admin)
--
--   1. Añade `public.profiles.account_type` ('customer' | 'admin') para
--      recordar el tipo de cuenta sin otorgar privilegios globales legacy
--      en `public.user_roles` (evita abrir RLS multiempresa con `is_staff()`).
--   2. `private.handle_new_user()` lee `account_type` / `role` de
--      `raw_user_meta_data` al crear el usuario y guarda `account_type`.
--      Conserva `public.user_roles` ('customer', y 'admin' solo para
--      `private.bootstrap_admins`).
--   3. `public.profile_set_account_type(text)` permite completar el tipo
--      de cuenta en flujos OAuth (ej. Google al registrarse como admin).
--   4. `public.business_register()` actualiza `profiles.account_type = 'admin'`.
--   5. `public.get_my_app_roles()` incluye `'admin'` cuando `profiles.account_type = 'admin'`.
-- =====================================================================

alter table public.profiles
  add column if not exists account_type text not null default 'customer';

do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'profiles_account_type_valid'
       and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_account_type_valid
      check (account_type in ('customer', 'admin'));
  end if;
end;
$$;

comment on column public.profiles.account_type is
  'Tipo de cuenta elegido al registrarse (customer o admin). No otorga permisos globales legacy.';

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_full_name text;
  v_account_type text;
begin
  v_full_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    ''
  );

  v_account_type := case
    when coalesce(
           nullif(lower(btrim(new.raw_user_meta_data ->> 'account_type')), ''),
           nullif(lower(btrim(new.raw_user_meta_data ->> 'role')), '')
         ) = 'admin'
      or exists (
           select 1
             from private.bootstrap_admins b
            where b.email = lower(btrim(coalesce(new.email, '')))
         )
      then 'admin'
    else 'customer'
  end;

  insert into public.profiles (id, full_name, email, nickname, account_type)
  values (
    new.id,
    v_full_name,
    coalesce(new.email, ''),
    private.nickname_generate(v_full_name),
    v_account_type
  )
  on conflict (id) do update
    set email = excluded.email,
        full_name = case
          when public.profiles.full_name = '' then excluded.full_name
          else public.profiles.full_name
        end,
        account_type = case
          when excluded.account_type = 'admin' then 'admin'
          else public.profiles.account_type
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

revoke execute on function private.handle_new_user() from public, anon;

create or replace function public.profile_set_account_type(p_account_type text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_type text := lower(btrim(coalesce(p_account_type, '')));
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if v_type not in ('customer', 'admin') then
    raise exception 'invalid_account_type';
  end if;

  update public.profiles
     set account_type = case
           when exists (
             select 1 from public.business_memberships m
              where m.user_id = v_uid and m.role = 'admin'
           ) then 'admin'
           else v_type
         end
   where id = v_uid;

  return (select account_type from public.profiles where id = v_uid);
end;
$$;

revoke execute on function public.profile_set_account_type(text) from public, anon;
grant execute on function public.profile_set_account_type(text) to authenticated, service_role;

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

  update public.profiles
     set account_type = 'admin'
   where id = v_uid
     and account_type <> 'admin';

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

revoke execute on function public.business_register(text, text, text) from public, anon;
grant execute on function public.business_register(text, text, text) to authenticated, service_role;

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
    union all
    select 'admin'::text
      from public.profiles
     where id = auth.uid()
       and account_type = 'admin'
  ) s;
$$;

revoke execute on function public.get_my_app_roles() from public, anon;
grant execute on function public.get_my_app_roles() to authenticated, service_role;

-- Backfill para cuentas ya existentes con rol/metadato admin o membresía admin
update public.profiles p
   set account_type = 'admin'
  from auth.users u
 where p.id = u.id
   and p.account_type <> 'admin'
   and (
     coalesce(
       nullif(lower(btrim(u.raw_user_meta_data ->> 'account_type')), ''),
       nullif(lower(btrim(u.raw_user_meta_data ->> 'role')), '')
     ) = 'admin'
     or exists (
       select 1
         from public.business_memberships m
        where m.user_id = p.id
          and m.role = 'admin'
     )
     or exists (
       select 1
         from public.user_roles r
        where r.user_id = p.id
          and r.role = 'admin'
     )
   );
