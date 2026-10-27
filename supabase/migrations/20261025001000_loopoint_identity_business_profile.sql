-- =====================================================================
-- Loopoint F2 · M1 — Identidad, perfil de negocio y cliente frecuente
--
-- Cambios aditivos:
--   1. `profiles.nickname` único (sin distinguir mayúsculas), con formato
--      validado, lista de reservados y límite de 2 cambios explícitos.
--   2. Autogeneración de nickname a partir del nombre (trigger y RPC).
--   3. `profile_update`, `profile_nickname_available` y
--      `profile_nickname_ensure`; `get_my_profile` ampliado.
--   4. Perfil público del negocio: descripción, dirección, contacto, redes
--      y logo. `business_profile_get/update`; `business_public_get` ampliado.
--   5. Criterios configurables de cliente frecuente en `loyalty_programs`
--      y helpers `private.customer_frequency`,
--      `public.business_customer_frequency`.
--   6. `staff_list_customers` y `staff_get_customer` aceptan un negocio
--      opcional (compatibles con las llamadas actuales) y devuelven
--      nickname, frecuencia y última compra.
--
-- No se edita ninguna migración ya aplicada. Campañas: sin cambios.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Nickname en perfiles
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists nickname text,
  add column if not exists nickname_changes smallint not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'profiles_nickname_format'
       and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_nickname_format
      check (nickname is null or nickname ~ '^[a-z0-9._-]{3,24}$');
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'profiles_nickname_lowercase'
       and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_nickname_lowercase
      check (nickname is null or nickname = lower(nickname));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'profiles_nickname_changes_range'
       and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_nickname_changes_range
      check (nickname_changes between 0 and 2);
  end if;
end
$$;

create unique index if not exists profiles_nickname_lower_unique
  on public.profiles (lower(btrim(nickname)))
  where nickname is not null;

comment on column public.profiles.nickname is
  'Alias público único (minúsculas, 3-24, letras/números/punto/guion). No se muestra en QR ni datos de canje.';
comment on column public.profiles.nickname_changes is
  'Cambios explícitos de nickname. El valor inicial y el autogenerado no cuentan. Máximo 2.';

-- ---------------------------------------------------------------------
-- 2. Helpers de nickname
-- ---------------------------------------------------------------------
create or replace function private.nickname_base(p_full_name text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v_clean text;
  v_tokens text[];
  v_base text;
begin
  v_clean := translate(
    lower(coalesce(p_full_name, '')),
    'áàäâãéèëêíìïîóòöôõúùüûñç',
    'aaaaaeeeeiiiiooooouuuunc'
  );
  v_clean := regexp_replace(v_clean, '[^a-z0-9]+', ' ', 'g');
  v_tokens := regexp_split_to_array(btrim(v_clean), '\s+');

  if v_tokens is null or cardinality(v_tokens) = 0 or coalesce(v_tokens[1], '') = '' then
    v_base := 'cliente';
  elsif cardinality(v_tokens) = 1 then
    v_base := v_tokens[1];
  else
    v_base := v_tokens[1] || v_tokens[cardinality(v_tokens)];
  end if;

  v_base := substr(v_base, 1, 24);
  if length(v_base) < 3 then
    v_base := 'cliente';
  end if;
  return v_base;
end;
$$;

create or replace function private.nickname_is_reserved(p_nickname text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select lower(btrim(coalesce(p_nickname, ''))) = any (array[
    'admin', 'administrador', 'loopoint', 'loopoints', 'soporte', 'sistema',
    'root', 'api', 'staff', 'equipo', 'ayuda', 'help', 'null', 'undefined',
    'anonimo', 'anonymous', 'moderador', 'owner'
  ]::text[]);
$$;

create or replace function private.nickname_generate(p_full_name text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_base text := private.nickname_base(p_full_name);
  v_candidate text;
  v_i integer;
begin
  -- Si el nombre genera un alias reservado, se empieza por el sufijo 2.
  v_i := case when private.nickname_is_reserved(v_base) then 2 else 1 end;

  loop
    if v_i = 1 then
      v_candidate := v_base;
    else
      v_candidate := substr(v_base, 1, greatest(1, 24 - length(v_i::text))) || v_i::text;
    end if;

    if length(v_candidate) < 3 then
      v_candidate := 'cliente' || v_i::text;
    end if;

    if not private.nickname_is_reserved(v_candidate)
       and not exists (
         select 1 from public.profiles p
          where lower(btrim(p.nickname)) = v_candidate
       ) then
      return v_candidate;
    end if;

    v_i := v_i + 1;
    exit when v_i > 99;
  end loop;

  -- Fallback improbable: sufijo aleatorio de 4 caracteres hexadecimales.
  loop
    v_candidate := substr(v_base, 1, 19) || '-'
      || substr(encode(extensions.gen_random_bytes(3), 'hex'), 1, 4);
    if not exists (
      select 1 from public.profiles p
       where lower(btrim(p.nickname)) = v_candidate
    ) then
      return v_candidate;
    end if;
  end loop;
end;
$$;

-- El alta de usuarios genera el alias si el nombre lo permite.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_full_name text;
begin
  v_full_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    ''
  );

  insert into public.profiles (id, full_name, email, nickname)
  values (
    new.id,
    v_full_name,
    coalesce(new.email, ''),
    private.nickname_generate(v_full_name)
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
-- 3. RPC de perfil personal
-- ---------------------------------------------------------------------
create or replace function public.profile_nickname_ensure()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_profile
    from public.profiles
   where id = v_uid
   for update;

  if not found then
    raise exception 'profile_not_found';
  end if;

  if v_profile.nickname is not null then
    return v_profile.nickname;
  end if;

  v_profile.nickname := private.nickname_generate(v_profile.full_name);

  -- El autogenerado no incrementa el contador de cambios.
  update public.profiles
     set nickname = v_profile.nickname
   where id = v_uid;

  return v_profile.nickname;
end;
$$;

create or replace function public.profile_nickname_available(p_nickname text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_nick text := lower(btrim(coalesce(p_nickname, '')));
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if v_nick !~ '^[a-z0-9._-]{3,24}$' then
    return false;
  end if;
  if private.nickname_is_reserved(v_nick) then
    return false;
  end if;

  return not exists (
    select 1 from public.profiles p
     where lower(btrim(p.nickname)) = v_nick
       and p.id <> v_uid
  );
end;
$$;

create or replace function public.profile_update(
  p_full_name text default null,
  p_nickname text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles;
  v_name text;
  v_nick text;
  v_changes smallint;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_profile
    from public.profiles
   where id = v_uid
   for update;

  if not found then
    raise exception 'profile_not_found';
  end if;

  v_name := v_profile.full_name;
  v_nick := v_profile.nickname;
  v_changes := v_profile.nickname_changes;

  if p_full_name is not null then
    v_name := btrim(p_full_name);
    if length(v_name) < 2 or length(v_name) > 120 then
      raise exception 'invalid_full_name';
    end if;
  end if;

  if p_nickname is not null then
    v_nick := lower(btrim(p_nickname));

    if v_nick !~ '^[a-z0-9._-]{3,24}$' then
      raise exception 'invalid_nickname';
    end if;
    if private.nickname_is_reserved(v_nick) then
      raise exception 'nickname_reserved';
    end if;

    if v_nick is distinct from v_profile.nickname then
      if exists (
        select 1 from public.profiles p
         where lower(btrim(p.nickname)) = v_nick
           and p.id <> v_uid
      ) then
        raise exception 'nickname_taken';
      end if;

      -- El primer valor (perfil sin alias) es gratuito.
      if v_profile.nickname is not null then
        if v_profile.nickname_changes >= 2 then
          raise exception 'nickname_change_limit';
        end if;
        v_changes := v_profile.nickname_changes + 1;
      end if;
    end if;
  end if;

  update public.profiles
     set full_name = v_name,
         nickname = v_nick,
         nickname_changes = v_changes
   where id = v_uid;

  return jsonb_build_object(
    'id', v_uid,
    'full_name', v_name,
    'email', v_profile.email,
    'nickname', v_nick,
    'nickname_changes', v_changes,
    'nickname_changes_left', 2 - v_changes,
    'business_count', (
      select count(*) from public.business_memberships m where m.user_id = v_uid
    )
  );
end;
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
    'nickname', p.nickname,
    'nickname_changes', p.nickname_changes,
    'nickname_changes_left', 2 - p.nickname_changes,
    'business_count', (
      select count(*) from public.business_memberships m where m.user_id = p.id
    ),
    'created_at', p.created_at
  )
  from public.profiles p
  where p.id = auth.uid();
$$;

grant execute on function public.profile_nickname_ensure() to authenticated;
grant execute on function public.profile_nickname_available(text) to authenticated;
grant execute on function public.profile_update(text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Perfil del negocio
-- ---------------------------------------------------------------------
alter table public.businesses
  add column if not exists description text,
  add column if not exists address text,
  add column if not exists neighborhood text,
  add column if not exists city text,
  add column if not exists phone_whatsapp text,
  add column if not exists phone text,
  add column if not exists instagram text,
  add column if not exists website text,
  add column if not exists logo_url text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'businesses_description_length'
       and conrelid = 'public.businesses'::regclass
  ) then
    alter table public.businesses
      add constraint businesses_description_length
      check (description is null or length(description) <= 500);
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'businesses_address_length'
       and conrelid = 'public.businesses'::regclass
  ) then
    alter table public.businesses
      add constraint businesses_address_length
      check (
        (address is null or length(address) <= 160)
        and (neighborhood is null or length(neighborhood) <= 160)
        and (city is null or length(city) <= 160)
      );
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'businesses_whatsapp_format'
       and conrelid = 'public.businesses'::regclass
  ) then
    alter table public.businesses
      add constraint businesses_whatsapp_format
      check (phone_whatsapp is null or phone_whatsapp ~ '^\+?[0-9]{7,15}$');
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'businesses_phone_format'
       and conrelid = 'public.businesses'::regclass
  ) then
    alter table public.businesses
      add constraint businesses_phone_format
      check (phone is null or phone ~ '^\+?[0-9]{7,15}$');
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'businesses_instagram_format'
       and conrelid = 'public.businesses'::regclass
  ) then
    alter table public.businesses
      add constraint businesses_instagram_format
      check (instagram is null or instagram ~ '^[A-Za-z0-9._]{1,30}$');
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'businesses_website_format'
       and conrelid = 'public.businesses'::regclass
  ) then
    alter table public.businesses
      add constraint businesses_website_format
      check (website is null or website ~* '^https?://[^[:space:]]{3,200}$');
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'businesses_logo_url_format'
       and conrelid = 'public.businesses'::regclass
  ) then
    alter table public.businesses
      add constraint businesses_logo_url_format
      check (logo_url is null or logo_url ~* '^https?://[^[:space:]]{3,255}$');
  end if;
end
$$;

comment on column public.businesses.logo_url is
  'URL pública del logo en el bucket business-assets. Se escribe solo con business_logo_set.';

create or replace function public.business_profile_get(p_business_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_business public.businesses;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  perform public.require_business_role(
    p_business_id,
    array['admin', 'encargado', 'cliente']
  );

  select * into v_business
    from public.businesses
   where id = p_business_id;

  return jsonb_build_object(
    'id', v_business.id,
    'name', v_business.name,
    'slug', v_business.slug,
    'timezone', v_business.timezone,
    'operating_days', to_jsonb(v_business.operating_days),
    'is_active', v_business.is_active,
    'description', v_business.description,
    'address', v_business.address,
    'neighborhood', v_business.neighborhood,
    'city', v_business.city,
    'phone_whatsapp', v_business.phone_whatsapp,
    'phone', v_business.phone,
    'instagram', v_business.instagram,
    'website', v_business.website,
    'logo_url', v_business.logo_url,
    'updated_at', v_business.updated_at
  );
end;
$$;

create or replace function public.business_profile_update(
  p_business_id uuid,
  p_name text,
  p_description text default null,
  p_address text default null,
  p_neighborhood text default null,
  p_city text default null,
  p_phone_whatsapp text default null,
  p_phone text default null,
  p_instagram text default null,
  p_website text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_business public.businesses;
  v_before jsonb;
  v_name text;
  v_description text;
  v_address text;
  v_neighborhood text;
  v_city text;
  v_whatsapp text;
  v_phone text;
  v_instagram text;
  v_website text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  perform public.require_business_role(p_business_id, array['admin']);

  select * into v_business
    from public.businesses
   where id = p_business_id
   for update;

  if not found then
    raise exception 'business_not_found';
  end if;

  v_before := to_jsonb(v_business);

  -- null = conservar; cadena vacía = borrar.
  v_name := case
    when p_name is null then v_business.name
    else btrim(p_name)
  end;
  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception 'invalid_business_name';
  end if;

  v_description := case
    when p_description is null then v_business.description
    when btrim(p_description) = '' then null
    else btrim(p_description)
  end;
  if v_description is not null and length(v_description) > 500 then
    raise exception 'invalid_business_description';
  end if;

  v_address := case
    when p_address is null then v_business.address
    when btrim(p_address) = '' then null
    else btrim(p_address)
  end;
  v_neighborhood := case
    when p_neighborhood is null then v_business.neighborhood
    when btrim(p_neighborhood) = '' then null
    else btrim(p_neighborhood)
  end;
  v_city := case
    when p_city is null then v_business.city
    when btrim(p_city) = '' then null
    else btrim(p_city)
  end;
  if length(coalesce(v_address, '')) > 160
     or length(coalesce(v_neighborhood, '')) > 160
     or length(coalesce(v_city, '')) > 160 then
    raise exception 'invalid_business_address';
  end if;

  v_whatsapp := case
    when p_phone_whatsapp is null then v_business.phone_whatsapp
    when btrim(p_phone_whatsapp) = '' then null
    else regexp_replace(btrim(p_phone_whatsapp), '[\s().-]', '', 'g')
  end;
  if v_whatsapp is not null and v_whatsapp !~ '^\+?[0-9]{7,15}$' then
    raise exception 'invalid_whatsapp';
  end if;

  v_phone := case
    when p_phone is null then v_business.phone
    when btrim(p_phone) = '' then null
    else regexp_replace(btrim(p_phone), '[\s().-]', '', 'g')
  end;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{7,15}$' then
    raise exception 'invalid_phone';
  end if;

  v_instagram := case
    when p_instagram is null then v_business.instagram
    when btrim(p_instagram) = '' then null
    else regexp_replace(
      rtrim(
        regexp_replace(
          regexp_replace(btrim(p_instagram), '^@', ''),
          '^https?://(www\.)?instagram\.com/', '', 'i'
        ),
        '/'
      ),
      '\?.*$', ''
    )
  end;
  if v_instagram is not null and v_instagram !~ '^[A-Za-z0-9._]{1,30}$' then
    raise exception 'invalid_instagram';
  end if;

  v_website := case
    when p_website is null then v_business.website
    when btrim(p_website) = '' then null
    else btrim(p_website)
  end;
  if v_website is not null then
    if v_website !~* '^https?://' then
      v_website := 'https://' || v_website;
    end if;
    if v_website !~* '^https?://[^[:space:]]{3,200}$' then
      raise exception 'invalid_website';
    end if;
  end if;

  update public.businesses
     set name = v_name,
         description = v_description,
         address = v_address,
         neighborhood = v_neighborhood,
         city = v_city,
         phone_whatsapp = v_whatsapp,
         phone = v_phone,
         instagram = v_instagram,
         website = v_website
   where id = p_business_id
  returning * into v_business;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'business.profile_updated',
    'business',
    p_business_id::text,
    jsonb_build_object(
      'before', jsonb_build_object(
        'name', v_before ->> 'name',
        'description', v_before ->> 'description',
        'address', v_before ->> 'address',
        'neighborhood', v_before ->> 'neighborhood',
        'city', v_before ->> 'city',
        'phone_whatsapp', v_before ->> 'phone_whatsapp',
        'phone', v_before ->> 'phone',
        'instagram', v_before ->> 'instagram',
        'website', v_before ->> 'website'
      ),
      'after', jsonb_build_object(
        'name', v_business.name,
        'description', v_business.description,
        'address', v_business.address,
        'neighborhood', v_business.neighborhood,
        'city', v_business.city,
        'phone_whatsapp', v_business.phone_whatsapp,
        'phone', v_business.phone,
        'instagram', v_business.instagram,
        'website', v_business.website
      )
    )
  );

  return public.business_profile_get(p_business_id);
end;
$$;

grant execute on function public.business_profile_get(uuid) to authenticated;
grant execute on function public.business_profile_update(
  uuid, text, text, text, text, text, text, text, text, text
) to authenticated;

-- Ficha pública: solo campos que puede ver cualquier visitante.
drop function if exists public.business_public_get(text);

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
  loyalty_active boolean,
  description text,
  logo_url text,
  address text,
  neighborhood text,
  city text,
  phone_whatsapp text,
  instagram text,
  website text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select b.id, b.name, b.slug, b.timezone, b.operating_days, b.is_active,
         coalesce(p.is_active, false),
         b.description, b.logo_url, b.address, b.neighborhood, b.city,
         b.phone_whatsapp, b.instagram, b.website
    from public.businesses b
    left join public.loyalty_programs p on p.business_id = b.id
   where b.slug = lower(btrim(p_slug))
     and b.is_active
   limit 1;
$$;

revoke execute on function public.business_public_get(text) from public;
grant execute on function public.business_public_get(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Criterios de cliente frecuente
-- ---------------------------------------------------------------------
alter table public.loyalty_programs
  add column if not exists frequent_min_purchases integer not null default 3,
  add column if not exists frequent_period_days integer not null default 90,
  add column if not exists frequent_min_spend_cop integer not null default 0,
  add column if not exists frequent_active_days integer not null default 30,
  add column if not exists recovery_inactive_days integer not null default 60;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'loyalty_programs_frequent_min_purchases'
       and conrelid = 'public.loyalty_programs'::regclass
  ) then
    alter table public.loyalty_programs
      add constraint loyalty_programs_frequent_min_purchases
      check (frequent_min_purchases between 1 and 100);
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'loyalty_programs_frequent_period_days'
       and conrelid = 'public.loyalty_programs'::regclass
  ) then
    alter table public.loyalty_programs
      add constraint loyalty_programs_frequent_period_days
      check (frequent_period_days between 7 and 3650);
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'loyalty_programs_frequent_min_spend'
       and conrelid = 'public.loyalty_programs'::regclass
  ) then
    alter table public.loyalty_programs
      add constraint loyalty_programs_frequent_min_spend
      check (frequent_min_spend_cop between 0 and 50000000);
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'loyalty_programs_frequent_active_days'
       and conrelid = 'public.loyalty_programs'::regclass
  ) then
    alter table public.loyalty_programs
      add constraint loyalty_programs_frequent_active_days
      check (frequent_active_days between 1 and 365);
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'loyalty_programs_recovery_days'
       and conrelid = 'public.loyalty_programs'::regclass
  ) then
    alter table public.loyalty_programs
      add constraint loyalty_programs_recovery_days
      check (
        recovery_inactive_days between 7 and 3650
        and recovery_inactive_days > frequent_active_days
      );
  end if;
end
$$;

comment on column public.loyalty_programs.frequent_min_purchases is
  'Compras necesarias dentro de la ventana para considerar frecuente al cliente.';
comment on column public.loyalty_programs.frequent_period_days is
  'Ventana móvil en días para contar compras y gasto.';
comment on column public.loyalty_programs.frequent_min_spend_cop is
  'Gasto mínimo acumulado dentro de la ventana. 0 = sin mínimo.';
comment on column public.loyalty_programs.frequent_active_days is
  'Días sin compras tras los cuales un frecuente deja de estar activo.';
comment on column public.loyalty_programs.recovery_inactive_days is
  'Días sin compras para marcar a un cliente en recuperación.';

-- `loyalty_program_get` devuelve la fila completa, pero cuando el programa
-- no existe se construye en memoria: hay que rellenar los criterios nuevos.
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
    v_program.frequent_min_purchases := 3;
    v_program.frequent_period_days := 90;
    v_program.frequent_min_spend_cop := 0;
    v_program.frequent_active_days := 30;
    v_program.recovery_inactive_days := 60;
  end if;

  return v_program;
end;
$$;

create or replace function public.loyalty_program_frequent_update(
  p_business_id uuid,
  p_min_purchases integer,
  p_period_days integer,
  p_min_spend_cop integer,
  p_active_days integer,
  p_recovery_days integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_before jsonb;
  v_program public.loyalty_programs;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  if p_min_purchases is null or p_min_purchases < 1 or p_min_purchases > 100 then
    raise exception 'invalid_frequent_min_purchases';
  end if;
  if p_period_days is null or p_period_days < 7 or p_period_days > 3650 then
    raise exception 'invalid_frequent_period_days';
  end if;
  if p_min_spend_cop is null or p_min_spend_cop < 0 or p_min_spend_cop > 50000000 then
    raise exception 'invalid_frequent_min_spend';
  end if;
  if p_active_days is null or p_active_days < 1 or p_active_days > 365 then
    raise exception 'invalid_frequent_active_days';
  end if;
  if p_recovery_days is null or p_recovery_days < 7 or p_recovery_days > 3650
     or p_recovery_days <= p_active_days then
    raise exception 'invalid_recovery_inactive_days';
  end if;

  select to_jsonb(r) into v_before
    from public.loyalty_programs r
   where r.business_id = p_business_id;

  insert into public.loyalty_programs (
    business_id, frequent_min_purchases, frequent_period_days,
    frequent_min_spend_cop, frequent_active_days, recovery_inactive_days
  ) values (
    p_business_id, p_min_purchases, p_period_days,
    p_min_spend_cop, p_active_days, p_recovery_days
  )
  on conflict (business_id) do update
    set frequent_min_purchases = excluded.frequent_min_purchases,
        frequent_period_days = excluded.frequent_period_days,
        frequent_min_spend_cop = excluded.frequent_min_spend_cop,
        frequent_active_days = excluded.frequent_active_days,
        recovery_inactive_days = excluded.recovery_inactive_days,
        updated_at = now()
  returning * into v_program;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'loyalty_program.frequent_updated',
    'loyalty_program',
    v_program.id::text,
    jsonb_build_object(
      'before', jsonb_build_object(
        'frequent_min_purchases', v_before ->> 'frequent_min_purchases',
        'frequent_period_days', v_before ->> 'frequent_period_days',
        'frequent_min_spend_cop', v_before ->> 'frequent_min_spend_cop',
        'frequent_active_days', v_before ->> 'frequent_active_days',
        'recovery_inactive_days', v_before ->> 'recovery_inactive_days'
      ),
      'after', jsonb_build_object(
        'frequent_min_purchases', v_program.frequent_min_purchases,
        'frequent_period_days', v_program.frequent_period_days,
        'frequent_min_spend_cop', v_program.frequent_min_spend_cop,
        'frequent_active_days', v_program.frequent_active_days,
        'recovery_inactive_days', v_program.recovery_inactive_days
      )
    )
  );

  return jsonb_build_object(
    'business_id', p_business_id,
    'frequent_min_purchases', v_program.frequent_min_purchases,
    'frequent_period_days', v_program.frequent_period_days,
    'frequent_min_spend_cop', v_program.frequent_min_spend_cop,
    'frequent_active_days', v_program.frequent_active_days,
    'recovery_inactive_days', v_program.recovery_inactive_days
  );
end;
$$;

grant execute on function public.loyalty_program_frequent_update(
  uuid, integer, integer, integer, integer, integer
) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Cálculo de frecuencia (por negocio y cliente)
-- ---------------------------------------------------------------------
create or replace function private.customer_frequency(
  p_business_id uuid,
  p_customer_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_min_purchases integer := 3;
  v_period_days integer := 90;
  v_min_spend integer := 0;
  v_active_days integer := 30;
  v_recovery_days integer := 60;
  v_count integer := 0;
  v_spend bigint := 0;
  v_last timestamptz;
  v_last_in_window timestamptz;
  v_frequent boolean := false;
  v_active boolean := false;
  v_recovering boolean := false;
begin
  if p_business_id is null or p_customer_id is null then
    return jsonb_build_object(
      'purchase_count', 0,
      'total_spent_cop', 0,
      'last_purchase_at', null,
      'is_frequent', false,
      'is_frequent_active', false,
      'is_recovering', false
    );
  end if;

  select
    p.frequent_min_purchases,
    p.frequent_period_days,
    p.frequent_min_spend_cop,
    p.frequent_active_days,
    p.recovery_inactive_days
    into
      v_min_purchases, v_period_days, v_min_spend,
      v_active_days, v_recovery_days
    from public.loyalty_programs p
   where p.business_id = p_business_id;

  if not found then
    v_min_purchases := 3;
    v_period_days := 90;
    v_min_spend := 0;
    v_active_days := 30;
    v_recovery_days := 60;
  end if;

  select count(*), coalesce(sum(e.amount_cop), 0), max(e.created_at)
    into v_count, v_spend, v_last_in_window
    from public.loyalty_purchase_events e
    join public.loyalty_point_accounts a on a.id = e.account_id
   where e.business_id = p_business_id
     and a.customer_id = p_customer_id
     and e.created_at >= now() - make_interval(days => v_period_days)
     and not exists (
       select 1
         from public.loyalty_point_transactions t
        where t.reference_type = 'purchase_event'
          and t.reference_id = e.id
          and t.movement_type = 'admin_adjustment'
          and t.points < 0
     );

  select max(e.created_at)
    into v_last
    from public.loyalty_purchase_events e
    join public.loyalty_point_accounts a on a.id = e.account_id
   where e.business_id = p_business_id
     and a.customer_id = p_customer_id
     and not exists (
       select 1
         from public.loyalty_point_transactions t
        where t.reference_type = 'purchase_event'
          and t.reference_id = e.id
          and t.movement_type = 'admin_adjustment'
          and t.points < 0
     );

  v_frequent := v_count >= v_min_purchases and v_spend >= v_min_spend;

  v_active := v_frequent
    and v_last_in_window is not null
    and v_last_in_window >= now() - make_interval(days => v_active_days);

  v_recovering := v_last is not null
    and not v_active
    and v_last <= now() - make_interval(days => v_recovery_days);

  return jsonb_build_object(
    'purchase_count', v_count,
    'total_spent_cop', v_spend,
    'last_purchase_at', v_last,
    'is_frequent', v_frequent,
    'is_frequent_active', v_active,
    'is_recovering', v_recovering
  );
end;
$$;

create or replace function public.business_customer_frequency(
  p_business_id uuid,
  p_customer_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  if v_uid = p_customer_id then
    perform public.business_current_membership(p_business_id);
  else
    perform public.require_business_role(p_business_id, array['admin', 'encargado']);
  end if;

  return private.customer_frequency(p_business_id, p_customer_id);
end;
$$;

grant execute on function public.business_customer_frequency(uuid, uuid) to authenticated;

-- Índice de apoyo para las consultas de frecuencia.
create index if not exists loyalty_purchase_events_business_account_idx
  on public.loyalty_purchase_events (business_id, account_id, created_at desc);

-- ---------------------------------------------------------------------
-- 7. Clientes para staff con nickname y frecuencia
--    Se añade `p_business_id` al final y valores por defecto para no
--    romper las llamadas existentes (compatibilidad aditiva).
-- ---------------------------------------------------------------------
drop function if exists public.staff_list_customers(text, integer, integer, text, text);

create or replace function public.staff_list_customers(
  p_search text default '',
  p_limit integer default 20,
  p_offset integer default 0,
  p_sort text default 'created_at',
  p_direction text default 'desc',
  p_business_id uuid default null
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
             $1 = ''
             or p.full_name ilike '%%' || $1 || '%%'
             or p.email ilike '%%' || $1 || '%%'
             or coalesce(p.nickname, '') ilike '%%' || $1 || '%%'
           )
     order by %s %s, p.id
     limit $2 offset $3
  $query$, v_order, v_dir)
  using v_search, v_limit, v_offset, p_business_id;
end;
$$;

grant execute on function public.staff_list_customers(
  text, integer, integer, text, text, uuid
) to authenticated;

drop function if exists public.staff_get_customer(uuid);

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
  else
    v_balance := coalesce(
      (select a.balance from public.loyalty_point_accounts a
        where a.business_id = p_business_id and a.customer_id = p_customer_id),
      0
    );
    v_purchase_count := coalesce((v_frequency ->> 'purchase_count')::integer, 0);
    v_total_spent := coalesce((v_frequency ->> 'total_spent_cop')::bigint, 0);
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
    'purchases', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.claimed_at desc)
      from (
        select pu.id, pu.amount_cop, pu.points_awarded, pu.claimed_at, pu.status
          from public.purchases pu
         where pu.claimed_by = p.id
           and pu.status = 'claimed'
           and (p_business_id is null or pu.business_id = p_business_id)
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
           and p_business_id is null
         order by l.created_at desc
         limit 50
      ) y
    ), '[]'::jsonb)
      || coalesce((
        select jsonb_agg(to_jsonb(z) order by z.created_at desc)
        from (
          select t.id, t.movement_type, t.points, t.reason, t.created_at
            from public.loyalty_point_transactions t
            join public.loyalty_point_accounts a on a.id = t.account_id
           where a.customer_id = p.id
             and t.business_id = p_business_id
             and p_business_id is not null
           order by t.created_at desc
           limit 50
        ) z
      ), '[]'::jsonb),
    'redemptions', coalesce((
      select jsonb_agg(to_jsonb(w) order by w.created_at desc)
      from (
        select r.id, r.reward_name, r.points_spent, r.code, r.status,
               r.created_at, r.delivered_at, r.cancelled_at
          from public.redemptions r
         where r.customer_id = p.id
         order by r.created_at desc
         limit 50
      ) w
    ), '[]'::jsonb)
  )
  into v_result
  from public.profiles p
  where p.id = p_customer_id;

  return v_result;
end;
$$;

grant execute on function public.staff_get_customer(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 8. Privilegios de las funciones internas nuevas
-- ---------------------------------------------------------------------
revoke execute on function private.nickname_base(text) from public;
revoke execute on function private.nickname_is_reserved(text) from public;
revoke execute on function private.nickname_generate(text) from public;
revoke execute on function private.customer_frequency(uuid, uuid) from public;
revoke execute on function public.profile_nickname_ensure() from public, anon;
revoke execute on function public.profile_nickname_available(text) from public, anon;
revoke execute on function public.profile_update(text, text) from public, anon;
revoke execute on function public.business_profile_get(uuid) from public, anon;
revoke execute on function public.business_profile_update(
  uuid, text, text, text, text, text, text, text, text, text
) from public, anon;
revoke execute on function public.loyalty_program_frequent_update(
  uuid, integer, integer, integer, integer, integer
) from public, anon;
revoke execute on function public.business_customer_frequency(uuid, uuid) from public, anon;
revoke execute on function public.staff_list_customers(
  text, integer, integer, text, text, uuid
) from public, anon;
revoke execute on function public.staff_get_customer(uuid, uuid) from public, anon;

-- ---------------------------------------------------------------------
-- 9. Comprobaciones
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'nickname'
  ) then
    raise exception 'profiles.nickname no existe';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'businesses'
       and column_name = 'logo_url'
  ) then
    raise exception 'businesses.logo_url no existe';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'loyalty_programs'
       and column_name = 'frequent_min_purchases'
  ) then
    raise exception 'loyalty_programs.frequent_min_purchases no existe';
  end if;
end
$$;
