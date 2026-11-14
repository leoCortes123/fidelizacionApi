-- Campos opcionales de teléfono y fecha de cumpleaños en el perfil del usuario.

alter table public.profiles
  add column if not exists phone text,
  add column if not exists birth_date date;

drop function if exists public.profile_update(text, text);

create or replace function public.profile_update(
  p_full_name text default null,
  p_nickname text default null,
  p_phone text default null,
  p_birth_date date default null,
  p_clear_birth_date boolean default false
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
  v_phone text;
  v_birth_date date;
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
  v_phone := v_profile.phone;
  v_birth_date := v_profile.birth_date;
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

  if p_phone is not null then
    v_phone := nullif(btrim(p_phone), '');
    if v_phone is not null and (
      length(v_phone) < 7
      or length(v_phone) > 25
      or v_phone !~ '^[0-9+\-\s()]+$'
      or length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 7
    ) then
      raise exception 'invalid_phone';
    end if;
  end if;

  if p_clear_birth_date then
    v_birth_date := null;
  elsif p_birth_date is not null then
    if p_birth_date > (now() at time zone 'America/Bogota')::date or p_birth_date < date '1900-01-01' then
      raise exception 'invalid_birth_date';
    end if;
    v_birth_date := p_birth_date;
  end if;

  update public.profiles
     set full_name = v_name,
         nickname = v_nick,
         nickname_changes = v_changes,
         phone = v_phone,
         birth_date = v_birth_date
   where id = v_uid;

  return jsonb_build_object(
    'id', v_uid,
    'full_name', v_name,
    'email', v_profile.email,
    'nickname', v_nick,
    'nickname_changes', v_changes,
    'nickname_changes_left', 2 - v_changes,
    'phone', v_phone,
    'birth_date', v_birth_date,
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
    'phone', p.phone,
    'birth_date', p.birth_date,
    'business_count', (
      select count(*) from public.business_memberships m where m.user_id = p.id
    ),
    'created_at', p.created_at
  )
  from public.profiles p
  where p.id = auth.uid();
$$;

revoke execute on function public.get_my_profile() from public, anon;
grant execute on function public.get_my_profile() to authenticated;

revoke execute on function public.profile_update(text, text, text, date, boolean) from public, anon;
grant execute on function public.profile_update(text, text, text, date, boolean) to authenticated;
