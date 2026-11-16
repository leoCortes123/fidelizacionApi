-- =====================================================================
-- Loopoint · Fotos de perfil de usuarios (`profiles.avatar_url`)
--            y fotos de recompensas (`loyalty_rewards.image_url`).
--
--   1. Columna `public.profiles.avatar_url` (nullable, ruta en `business-assets/avatars/<user_id>/...`).
--   2. Políticas de Storage para que cada usuario autenticado administre su avatar.
--   3. RPC `profile_avatar_set(p_avatar_url)` + inclusión de `avatar_url` en
--      `get_my_profile`, `profile_update`, `business_memberships_list`,
--      `business_search_profiles`, `staff_list_customers`, `staff_get_customer`,
--      `loyalty_redemptions_list` y `redemption_token_context`.
--   4. Columna `public.loyalty_rewards.image_url` (nullable, ruta en
--      `business-assets/business/<business_id>/...`).
--   5. `loyalty_reward_upsert` acepta `p_image_url` opcional y valida ruta del negocio.
--   6. `loyalty_rewards_list`, `loyalty_rewards_available`, `loyalty_my_redemptions`,
--      `loyalty_redemptions_list` y `redemption_token_context` devuelven la imagen.
-- =====================================================================

-- 1. Columna y constraint en `profiles`
alter table public.profiles
  add column if not exists avatar_url text;

comment on column public.profiles.avatar_url is
  'URL pública del avatar del usuario en Storage (bucket business-assets/avatars/<user_id>/...).';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'profiles_avatar_url_format'
       and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_avatar_url_format check (
        avatar_url is null or (
          length(avatar_url) <= 500
          and position('..' in avatar_url) = 0
          and avatar_url !~* '(%2e|%2f|%5c|\\)'
          and avatar_url ~* '^https?://[^/?#@[:space:]]+/storage/v1/object/public/business-assets/avatars/[^/?#@[:space:]]+/[^?#[:space:]]+$'
        )
      );
  end if;
end
$$;

-- 2. Políticas de Storage para avatares (`avatars/<auth.uid()>/...`)
do $$
begin
  if to_regclass('storage.buckets') is not null
     and to_regclass('storage.objects') is not null then
    drop policy if exists business_assets_avatar_insert on storage.objects;
    create policy business_assets_avatar_insert
      on storage.objects
      for insert
      to authenticated
      with check (
        bucket_id = 'business-assets'
        and split_part(name, '/', 1) = 'avatars'
        and split_part(name, '/', 2) = auth.uid()::text
      );

    drop policy if exists business_assets_avatar_update on storage.objects;
    create policy business_assets_avatar_update
      on storage.objects
      for update
      to authenticated
      using (
        bucket_id = 'business-assets'
        and split_part(name, '/', 1) = 'avatars'
        and split_part(name, '/', 2) = auth.uid()::text
      )
      with check (
        bucket_id = 'business-assets'
        and split_part(name, '/', 1) = 'avatars'
        and split_part(name, '/', 2) = auth.uid()::text
      );

    drop policy if exists business_assets_avatar_delete on storage.objects;
    create policy business_assets_avatar_delete
      on storage.objects
      for delete
      to authenticated
      using (
        bucket_id = 'business-assets'
        and split_part(name, '/', 1) = 'avatars'
        and split_part(name, '/', 2) = auth.uid()::text
      );
  end if;
end
$$;

-- 3. RPC `profile_avatar_set` y actualización de RPCs de perfil
create or replace function public.profile_avatar_set(
  p_avatar_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_url text := nullif(btrim(coalesce(p_avatar_url, '')), '');
  v_prefix text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if v_url is not null then
    if length(v_url) > 500
       or position('..' in v_url) > 0
       or v_url ~* '(%2e|%2f|%5c|\\)'
       or v_url !~* '^https?://[^/?#@[:space:]]+/storage/v1/object/public/business-assets/[^?#[:space:]]+$'
    then
      raise exception 'invalid_avatar_url';
    end if;

    v_prefix := '^https?://[^/?#@[:space:]]+/storage/v1/object/public/business-assets/avatars/'
      || v_uid::text || '/[^?#[:space:]]+$';
    if v_url !~* v_prefix then
      raise exception 'avatar_outside_user';
    end if;
  end if;

  update public.profiles
     set avatar_url = v_url
   where id = v_uid;

  if not found then
    raise exception 'profile_not_found';
  end if;

  return jsonb_build_object(
    'id', v_uid,
    'avatar_url', v_url
  );
end;
$$;

revoke all on function public.profile_avatar_set(text) from public, anon;
grant execute on function public.profile_avatar_set(text) to authenticated;

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
    'avatar_url', v_profile.avatar_url,
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
    'avatar_url', p.avatar_url,
    'business_count', (
      select count(*) from public.business_memberships m where m.user_id = p.id
    ),
    'created_at', p.created_at
  )
  from public.profiles p
  where p.id = auth.uid();
$$;

-- 4. Miembros, búsqueda de perfiles y clientes con `avatar_url`
drop function if exists public.business_memberships_list(uuid);

create or replace function public.business_memberships_list(
  p_business_id uuid
)
returns table (
  id uuid,
  user_id uuid,
  full_name text,
  email text,
  avatar_url text,
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
    select m.id, m.user_id, p.full_name, p.email, p.avatar_url, m.role,
           m.can_approve_redemptions, m.created_at
      from public.business_memberships m
      join public.profiles p on p.id = m.user_id
     where m.business_id = p_business_id
     order by m.role, p.full_name;
end;
$$;

revoke all on function public.business_memberships_list(uuid) from public, anon;
grant execute on function public.business_memberships_list(uuid) to authenticated;

drop function if exists public.business_search_profiles(uuid, text);

create or replace function public.business_search_profiles(
  p_business_id uuid,
  p_query text default ''
)
returns table (
  user_id uuid,
  full_name text,
  email text,
  avatar_url text,
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
    select p.id, p.full_name, p.email, p.avatar_url, (m.user_id is not null)
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

revoke all on function public.business_search_profiles(uuid, text) from public, anon;
grant execute on function public.business_search_profiles(uuid, text) to authenticated;

drop function if exists public.staff_list_customers(
  text, integer, integer, text, text, uuid, boolean
);

create or replace function public.staff_list_customers(
  p_search text default '',
  p_limit integer default 20,
  p_offset integer default 0,
  p_sort text default 'created_at',
  p_direction text default 'desc',
  p_business_id uuid default null,
  p_only_frequent boolean default false
)
returns table (
  id uuid,
  full_name text,
  email text,
  avatar_url text,
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
           p.avatar_url,
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
             not coalesce($5, false)
             or coalesce((f.f ->> 'is_frequent')::boolean, false)
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
  using v_search, v_limit, v_offset, p_business_id, p_only_frequent;
end;
$$;

grant execute on function public.staff_list_customers(
  text, integer, integer, text, text, uuid, boolean
) to authenticated;
revoke execute on function public.staff_list_customers(
  text, integer, integer, text, text, uuid, boolean
) from public, anon;

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
  v_purchases jsonb;
  v_movements jsonb;
  v_redemptions jsonb;
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

    select coalesce(jsonb_agg(to_jsonb(x) order by x.claimed_at desc), '[]'::jsonb)
      into v_purchases
      from (
        select pu.id, pu.amount_cop, pu.points_awarded, pu.claimed_at, pu.status,
               (select count(*)::integer from public.purchase_items pi
                 where pi.purchase_id = pu.id) as items_count,
               'qr'::text as source
          from public.purchases pu
         where pu.claimed_by = p_customer_id and pu.status = 'claimed'
         order by pu.claimed_at desc
         limit 50
      ) x;

    select coalesce(jsonb_agg(to_jsonb(y) order by y.created_at desc), '[]'::jsonb)
      into v_movements
      from (
        select l.id, l.movement_type, l.points, l.reason, l.created_at
          from public.points_ledger l
         where l.customer_id = p_customer_id
         order by l.created_at desc
         limit 50
      ) y;

    select coalesce(jsonb_agg(to_jsonb(z) order by z.created_at desc), '[]'::jsonb)
      into v_redemptions
      from (
        select r.id, r.reward_name, r.points_spent, r.code,
               r.status::text as status, r.created_at, r.delivered_at
          from public.redemptions r
         where r.customer_id = p_customer_id
         order by r.created_at desc
         limit 50
      ) z;
  else
    select coalesce(a.balance, 0) into v_balance
      from public.loyalty_point_accounts a
     where a.business_id = p_business_id and a.customer_id = p_customer_id;

    v_balance := coalesce(v_balance, 0);

    select count(*)::integer, coalesce(sum(e.amount_cop), 0)::bigint
      into v_purchase_count, v_total_spent
      from public.loyalty_purchase_events e
      join public.loyalty_point_accounts a on a.id = e.account_id
     where e.business_id = p_business_id
       and a.customer_id = p_customer_id;

    select coalesce(jsonb_agg(to_jsonb(x) order by x.claimed_at desc), '[]'::jsonb)
      into v_purchases
      from (
        select *
          from (
            select pu.id,
                   pu.amount_cop,
                   pu.points_awarded,
                   pu.claimed_at,
                   'claimed'::public.purchase_status as status,
                   (select count(*)::integer from public.purchase_items pi
                     where pi.purchase_id = pu.id) as items_count,
                   'qr'::text as source
              from public.purchases pu
             where pu.business_id = p_business_id
               and pu.claimed_by = p_customer_id
               and pu.status = 'claimed'
            union all
            select e.id,
                   e.amount_cop,
                   e.points_earned,
                   e.created_at,
                   'claimed'::public.purchase_status,
                   0,
                   'manual'::text
              from public.loyalty_purchase_events e
              join public.loyalty_point_accounts a on a.id = e.account_id
             where e.business_id = p_business_id
               and a.customer_id = p_customer_id
               and e.purchase_id is null
          ) u
         order by u.claimed_at desc
         limit 50
      ) x;

    select coalesce(jsonb_agg(to_jsonb(y) order by y.created_at desc), '[]'::jsonb)
      into v_movements
      from (
        select t.id, t.movement_type, t.points, t.reason, t.created_at
          from public.loyalty_point_transactions t
          join public.loyalty_point_accounts a on a.id = t.account_id
         where a.customer_id = p_customer_id
           and t.business_id = p_business_id
         order by t.created_at desc
         limit 50
      ) y;

    select coalesce(jsonb_agg(to_jsonb(z) order by z.created_at desc), '[]'::jsonb)
      into v_redemptions
      from (
        select r.id,
               r.reward_name,
               r.points_spent,
               r.code,
               case r.status
                 when 'delivered' then 'redeemed'
                 when 'cancelled' then 'cancelled'
                 when 'expired' then 'cancelled'
                 else 'pending_delivery'
               end as status,
               r.created_at,
               r.delivered_at,
               r.cancelled_at
          from public.loyalty_redemptions r
          join public.loyalty_point_accounts a on a.id = r.account_id
         where r.business_id = p_business_id
           and a.customer_id = p_customer_id
         order by r.created_at desc
         limit 50
      ) z;
  end if;

  select jsonb_build_object(
    'profile', jsonb_build_object(
      'id', p.id,
      'full_name', p.full_name,
      'email', p.email,
      'nickname', p.nickname,
      'avatar_url', p.avatar_url,
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
    'purchases', v_purchases,
    'movements', v_movements,
    'redemptions', v_redemptions
  )
  into v_result
  from public.profiles p
  where p.id = p_customer_id;

  return v_result;
end;
$$;

-- 5. Columna y constraint en `loyalty_rewards`
alter table public.loyalty_rewards
  add column if not exists image_url text;

comment on column public.loyalty_rewards.image_url is
  'URL pública de la foto de la recompensa en Storage (bucket business-assets/business/<business_id>/...).';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'loyalty_rewards_image_url_format'
       and conrelid = 'public.loyalty_rewards'::regclass
  ) then
    alter table public.loyalty_rewards
      add constraint loyalty_rewards_image_url_format check (
        image_url is null or (
          length(image_url) <= 500
          and position('..' in image_url) = 0
          and image_url !~* '(%2e|%2f|%5c|\\)'
          and image_url ~* '^https?://[^/?#@[:space:]]+/storage/v1/object/public/business-assets/business/[^/?#@[:space:]]+/[^?#[:space:]]+$'
        )
      );
  end if;
end
$$;

-- 6. `loyalty_reward_upsert` con `p_image_url`
drop function if exists public.loyalty_reward_upsert(
  uuid, public.loyalty_reward_type, text, integer, uuid, uuid, text, integer,
  integer, numeric, timestamptz, timestamptz, integer, integer, integer, integer, boolean
);

create or replace function public.loyalty_reward_upsert(
  p_business_id uuid,
  p_type public.loyalty_reward_type,
  p_name text,
  p_points_required integer,
  p_id uuid default null,
  p_product_id uuid default null,
  p_description text default '',
  p_min_purchase_amount integer default 0,
  p_max_discount_amount integer default null,
  p_discount_percentage numeric default null,
  p_valid_from timestamptz default null,
  p_valid_until timestamptz default null,
  p_max_redemptions_per_customer integer default null,
  p_max_redemptions_per_period integer default null,
  p_redemption_period_days integer default null,
  p_total_redemption_limit integer default null,
  p_is_active boolean default true,
  p_image_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_price_cop integer;
  v_cost_cop integer;
  v_discount_percentage numeric := p_discount_percentage;
  v_max_discount_amount integer := p_max_discount_amount;
  v_image_url text := nullif(btrim(coalesce(p_image_url, '')), '');
  v_image_prefix text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  if length(btrim(coalesce(p_name, ''))) < 2 then
    raise exception 'invalid_reward_name';
  end if;
  if p_points_required <= 0 or p_points_required > 10000000 then
    raise exception 'invalid_reward_points';
  end if;
  if p_min_purchase_amount < 0 then
    raise exception 'invalid_min_purchase';
  end if;
  if p_valid_from is not null and p_valid_until is not null and p_valid_until <= p_valid_from then
    raise exception 'invalid_reward_validity';
  end if;
  if p_max_redemptions_per_period is not null then
    if p_max_redemptions_per_period < 1 then
      raise exception 'invalid_redemption_limit';
    end if;
    if p_redemption_period_days is null
       or p_redemption_period_days < 1
       or p_redemption_period_days > 3650 then
      raise exception 'invalid_redemption_period';
    end if;
  end if;
  if p_max_redemptions_per_customer is not null and p_max_redemptions_per_customer < 1 then
    raise exception 'invalid_redemption_limit';
  end if;
  if p_total_redemption_limit is not null and p_total_redemption_limit < 1 then
    raise exception 'invalid_redemption_limit';
  end if;

  if v_image_url is not null then
    if length(v_image_url) > 500
       or position('..' in v_image_url) > 0
       or v_image_url ~* '(%2e|%2f|%5c|\\)'
       or v_image_url !~* '^https?://[^/?#@[:space:]]+/storage/v1/object/public/business-assets/[^?#[:space:]]+$'
    then
      raise exception 'invalid_reward_image_url';
    end if;

    v_image_prefix := '^https?://[^/?#@[:space:]]+/storage/v1/object/public/business-assets/business/'
      || p_business_id::text || '/[^?#[:space:]]+$';
    if v_image_url !~* v_image_prefix then
      raise exception 'reward_image_outside_business';
    end if;
  end if;

  if p_type = 'percentage_discount' then
    if p_discount_percentage is null or p_discount_percentage <= 0 or p_discount_percentage > 100 then
      raise exception 'invalid_discount_percentage';
    end if;
    v_max_discount_amount := p_max_discount_amount;
  elsif p_type = 'fixed_discount' then
    if p_max_discount_amount is null or p_max_discount_amount <= 0 then
      raise exception 'invalid_max_discount';
    end if;
    v_discount_percentage := null;
  elsif p_type = 'configurable_benefit' then
    v_discount_percentage := null;
  else
    v_discount_percentage := null;
    v_max_discount_amount := null;
  end if;

  if v_max_discount_amount is not null and v_max_discount_amount < 0 then
    raise exception 'invalid_max_discount';
  end if;
  if v_max_discount_amount is not null
     and p_min_purchase_amount > 0
     and v_max_discount_amount > p_min_purchase_amount then
    raise exception 'discount_exceeds_min_purchase';
  end if;

  if p_type = 'free_product' then
    if p_product_id is null then
      raise exception 'free_product_requires_product';
    end if;
    select price_cop, cost_cop into v_price_cop, v_cost_cop
      from public.products
     where id = p_product_id and business_id = p_business_id;
    if not found then
      raise exception 'product_not_found';
    end if;
  else
    v_price_cop := null;
    v_cost_cop := null;
  end if;

  if p_id is null then
    insert into public.loyalty_rewards (
      business_id, product_id, type, name, description, points_required,
      min_purchase_amount, max_discount_amount, discount_percentage,
      product_price_cop, product_cost_cop, valid_from, valid_until,
      max_redemptions_per_customer, max_redemptions_per_period,
      redemption_period_days, total_redemption_limit, is_active, image_url, created_by
    ) values (
      p_business_id, p_product_id, p_type, btrim(p_name),
      btrim(coalesce(p_description, '')), p_points_required,
      p_min_purchase_amount, v_max_discount_amount, v_discount_percentage,
      v_price_cop, v_cost_cop, p_valid_from, p_valid_until,
      p_max_redemptions_per_customer, p_max_redemptions_per_period,
      case when p_max_redemptions_per_period is null then null else p_redemption_period_days end,
      p_total_redemption_limit, p_is_active, v_image_url, v_uid
    )
    returning id into v_id;
  else
    update public.loyalty_rewards
       set product_id = p_product_id,
           type = p_type,
           name = btrim(p_name),
           description = btrim(coalesce(p_description, '')),
           points_required = p_points_required,
           min_purchase_amount = p_min_purchase_amount,
           max_discount_amount = v_max_discount_amount,
           discount_percentage = v_discount_percentage,
           product_price_cop = v_price_cop,
           product_cost_cop = v_cost_cop,
           valid_from = p_valid_from,
           valid_until = p_valid_until,
           max_redemptions_per_customer = p_max_redemptions_per_customer,
           max_redemptions_per_period = p_max_redemptions_per_period,
           redemption_period_days = case
             when p_max_redemptions_per_period is null then null
             else p_redemption_period_days
           end,
           total_redemption_limit = p_total_redemption_limit,
           is_active = p_is_active,
           image_url = v_image_url,
           updated_at = now()
     where id = p_id and business_id = p_business_id
    returning id into v_id;
    if v_id is null then raise exception 'reward_not_found'; end if;
  end if;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    case when p_id is null then 'reward.created' else 'reward.updated' end,
    'loyalty_reward',
    v_id::text,
    jsonb_build_object(
      'name', p_name, 'type', p_type, 'points_required', p_points_required,
      'product_id', p_product_id, 'is_active', p_is_active, 'image_url', v_image_url
    )
  );

  return (select to_jsonb(r) from public.loyalty_rewards r where r.id = v_id);
end;
$$;

revoke all on function public.loyalty_reward_upsert(
  uuid, public.loyalty_reward_type, text, integer, uuid, uuid, text, integer,
  integer, numeric, timestamptz, timestamptz, integer, integer, integer, integer, boolean, text
) from public, anon;
grant execute on function public.loyalty_reward_upsert(
  uuid, public.loyalty_reward_type, text, integer, uuid, uuid, text, integer,
  integer, numeric, timestamptz, timestamptz, integer, integer, integer, integer, boolean, text
) to authenticated;

-- 7. `loyalty_rewards_list` y `loyalty_rewards_available` con `image_url`
drop function if exists public.loyalty_rewards_list(uuid, boolean);

create or replace function public.loyalty_rewards_list(
  p_business_id uuid,
  p_only_active boolean default true
)
returns table (
  id uuid,
  product_id uuid,
  type public.loyalty_reward_type,
  name text,
  description text,
  points_required integer,
  min_purchase_amount integer,
  max_discount_amount integer,
  discount_percentage numeric,
  product_price_cop integer,
  product_cost_cop integer,
  is_active boolean,
  valid_from timestamptz,
  valid_until timestamptz,
  max_redemptions_per_customer integer,
  max_redemptions_per_period integer,
  redemption_period_days integer,
  total_redemption_limit integer,
  image_url text,
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
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  return query
    select r.id, r.product_id, r.type, r.name, r.description, r.points_required,
           r.min_purchase_amount, r.max_discount_amount, r.discount_percentage,
           r.product_price_cop, r.product_cost_cop, r.is_active,
           r.valid_from, r.valid_until, r.max_redemptions_per_customer,
           r.max_redemptions_per_period, r.redemption_period_days,
           r.total_redemption_limit, r.image_url, r.created_at, r.updated_at,
           coalesce((select count(*) from public.loyalty_redemptions d
                      where d.reward_id = r.id and d.status = 'delivered'), 0)::bigint
      from public.loyalty_rewards r
     where r.business_id = p_business_id
       and (not p_only_active or r.is_active)
     order by r.points_required asc, r.name asc;
end;
$$;

revoke all on function public.loyalty_rewards_list(uuid, boolean) from public, anon;
grant execute on function public.loyalty_rewards_list(uuid, boolean) to authenticated;

drop function if exists public.loyalty_rewards_available(uuid, uuid);

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
  valid_until timestamptz,
  image_url text
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
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  v_membership := public.business_current_membership(p_business_id);

  v_customer_id := case
    when v_membership.role = 'admin' then p_customer_id
    else v_uid
  end;

  select coalesce(lpa.balance, 0) into v_balance
    from public.loyalty_point_accounts lpa
   where lpa.business_id = p_business_id and lpa.customer_id = v_customer_id;

  v_balance := coalesce(v_balance, 0);

  return query
    select r.id, r.type, r.name, r.description, r.points_required,
           r.min_purchase_amount, r.max_discount_amount, r.discount_percentage,
           r.product_price_cop,
           case when v_membership.role = 'admin' then r.product_cost_cop else null end,
           v_balance,
           greatest(r.points_required - v_balance, 0),
           v_balance >= r.points_required
             and r.is_active
             and (r.valid_from is null or r.valid_from <= v_now)
             and (r.valid_until is null or r.valid_until > v_now),
           r.valid_from, r.valid_until, r.image_url
      from public.loyalty_rewards r
     where r.business_id = p_business_id
       and r.is_active
       and (r.valid_from is null or r.valid_from <= v_now)
       and (r.valid_until is null or r.valid_until > v_now)
     order by r.points_required asc, r.name asc;
end;
$$;

revoke all on function public.loyalty_rewards_available(uuid, uuid) from public, anon;
grant execute on function public.loyalty_rewards_available(uuid, uuid) to authenticated;

-- 8. Canjes con `reward_image_url` y `customer_avatar_url`
drop function if exists public.loyalty_my_redemptions(integer, integer);

create or replace function public.loyalty_my_redemptions(
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  id uuid,
  business_id uuid,
  business_name text,
  business_slug text,
  business_logo_url text,
  reward_name text,
  reward_type public.loyalty_reward_type,
  reward_image_url text,
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
    select r.id, r.business_id, b.name, b.slug, b.logo_url,
           r.reward_name, r.reward_type, rw.image_url, r.points_spent, r.code, r.status,
           r.created_at, r.approved_at, r.delivered_at, r.cancelled_at
      from public.loyalty_redemptions r
      join public.loyalty_point_accounts a on a.id = r.account_id
      join public.businesses b on b.id = r.business_id
      left join public.loyalty_rewards rw on rw.id = r.reward_id
     where a.customer_id = v_uid
     order by r.created_at desc
     limit v_limit offset v_offset;
end;
$$;

grant execute on function public.loyalty_my_redemptions(integer, integer) to authenticated;
revoke execute on function public.loyalty_my_redemptions(integer, integer) from public, anon;

drop function if exists public.loyalty_redemptions_list(
  uuid, public.redemption_request_status, integer, integer, text
);

create or replace function public.loyalty_redemptions_list(
  p_business_id uuid,
  p_status public.redemption_request_status default null,
  p_limit integer default 100,
  p_offset integer default 0,
  p_origin text default null
)
returns table (
  id uuid,
  reward_name text,
  reward_type public.loyalty_reward_type,
  reward_image_url text,
  points_spent integer,
  code text,
  status public.redemption_request_status,
  created_at timestamptz,
  approved_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  customer_id uuid,
  customer_email text,
  customer_avatar_url text,
  origin text,
  customer_nickname text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  if p_origin is not null and p_origin not in ('manual', 'qr_scan') then
    raise exception 'invalid_origin';
  end if;

  return query
    select r.id, r.reward_name, r.reward_type, rw.image_url, r.points_spent, r.code, r.status,
           r.created_at, r.approved_at, r.delivered_at, r.cancelled_at,
           a.customer_id, p.email, p.avatar_url, r.origin, p.nickname
      from public.loyalty_redemptions r
      join public.loyalty_point_accounts a on a.id = r.account_id
      join public.profiles p on p.id = a.customer_id
      left join public.loyalty_rewards rw on rw.id = r.reward_id
     where r.business_id = p_business_id
       and (p_status is null or r.status = p_status)
       and (p_origin is null or r.origin = p_origin)
     order by r.created_at desc
     limit v_limit offset v_offset;
end;
$$;

revoke all on function public.loyalty_redemptions_list(
  uuid, public.redemption_request_status, integer, integer, text
) from public, anon;
grant execute on function public.loyalty_redemptions_list(
  uuid, public.redemption_request_status, integer, integer, text
) to authenticated;

create or replace function public.redemption_token_context(
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_token public.loyalty_redemption_tokens;
  v_redemption public.loyalty_redemptions;
  v_membership public.business_memberships;
  v_business public.businesses;
  v_nickname text;
  v_customer_avatar_url text;
  v_reward_image_url text;
  v_customer_id uuid;
  v_can_redeem boolean := false;
  v_reason text;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  perform private.consume_rate_limit('redemption_scan_context:' || v_uid::text, 60, 60);

  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');

  select * into v_token
    from public.loyalty_redemption_tokens
   where token_hash = v_hash;

  if not found then
    raise exception 'invalid_token';
  end if;

  v_membership := public.business_current_membership(v_token.business_id);

  if v_membership.role not in ('admin', 'encargado') then
    raise exception 'forbidden';
  end if;
  if v_membership.role = 'encargado' and not v_membership.can_approve_redemptions then
    raise exception 'forbidden';
  end if;

  select * into v_redemption
    from public.loyalty_redemptions
   where id = v_token.redemption_id
     and business_id = v_token.business_id;

  if not found then
    raise exception 'redemption_not_found';
  end if;

  select * into v_business
    from public.businesses
   where id = v_redemption.business_id;

  select a.customer_id, p.nickname, p.avatar_url
    into v_customer_id, v_nickname, v_customer_avatar_url
    from public.loyalty_point_accounts a
    join public.profiles p on p.id = a.customer_id
   where a.id = v_redemption.account_id;

  select rw.image_url into v_reward_image_url
    from public.loyalty_rewards rw
   where rw.id = v_redemption.reward_id;

  if v_redemption.status = 'delivered' then
    v_reason := 'redemption_already_delivered';
  elsif v_redemption.status = 'cancelled' then
    v_reason := 'redemption_cancelled';
  elsif v_redemption.status = 'expired' then
    v_reason := 'redemption_expired';
  elsif v_redemption.status <> 'pending' then
    v_reason := 'redemption_not_pending';
  elsif v_token.consumed_at is not null then
    v_reason := 'token_already_consumed';
  elsif v_token.expires_at <= v_now then
    v_reason := 'token_expired';
  else
    v_can_redeem := true;
  end if;

  return jsonb_build_object(
    'business_id', v_redemption.business_id,
    'business_name', v_business.name,
    'business_slug', v_business.slug,
    'business_logo_url', v_business.logo_url,
    'redemption_id', v_redemption.id,
    'code', v_redemption.code,
    'reward_name', v_redemption.reward_name,
    'reward_type', v_redemption.reward_type,
    'reward_image_url', v_reward_image_url,
    'points_spent', v_redemption.points_spent,
    'customer_id', v_customer_id,
    'customer_nickname', v_nickname,
    'customer_avatar_url', v_customer_avatar_url,
    'status', v_redemption.status,
    'origin', v_redemption.origin,
    'created_at', v_redemption.created_at,
    'expires_at', v_token.expires_at,
    'consumed_at', v_token.consumed_at,
    'approved_at', v_redemption.approved_at,
    'delivered_at', v_redemption.delivered_at,
    'can_redeem', v_can_redeem,
    'reason', v_reason,
    'role', v_membership.role
  );
end;
$$;

revoke all on function public.redemption_token_context(text) from public, anon;
grant execute on function public.redemption_token_context(text) to authenticated;

-- 9. `businesses_list` con `logo_url`
drop function if exists public.businesses_list();

create or replace function public.businesses_list()
returns table (
  id uuid,
  name text,
  slug text,
  logo_url text,
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
    select b.id, b.name, b.slug, b.logo_url, b.timezone, b.operating_days, b.is_active,
           b.created_by, b.created_at, b.updated_at,
           m.role, m.can_approve_redemptions
      from public.businesses b
      join public.business_memberships m
        on m.business_id = b.id and m.user_id = v_uid
     order by b.created_at desc;
end;
$$;

revoke all on function public.businesses_list() from public, anon;
grant execute on function public.businesses_list() to authenticated;

-- 10. Comprobaciones de integridad
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles' and column_name = 'avatar_url'
  ) then
    raise exception 'falta columna profiles.avatar_url';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'loyalty_rewards' and column_name = 'image_url'
  ) then
    raise exception 'falta columna loyalty_rewards.image_url';
  end if;
end
$$;
