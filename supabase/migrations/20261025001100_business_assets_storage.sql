-- =====================================================================
-- Loopoint F2 · M2 — Bucket de imágenes del negocio y logo
--
--   1. Bucket público de lectura `business-assets` (2 MB, JPEG/PNG/WebP).
--   2. Políticas de Storage: solo el administrador del negocio puede
--      escribir dentro de `business/<business_id>/...`.
--   3. `business_logo_set`: valida la URL pública del bucket y la ruta del
--      negocio, guarda `businesses.logo_url` y audita el cambio.
--
-- La migración se puede aplicar en PostgreSQL puro (pruebas): si el
-- esquema `storage` no existe, solo se crean las RPC y sus validaciones.
-- =====================================================================

do $$
begin
  if to_regclass('storage.buckets') is not null
     and to_regclass('storage.objects') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values (
      'business-assets',
      'business-assets',
      true,
      2097152,
      array['image/jpeg', 'image/png', 'image/webp']::text[]
    )
    on conflict (id) do update
      set public = excluded.public,
          file_size_limit = excluded.file_size_limit,
          allowed_mime_types = excluded.allowed_mime_types;

    drop policy if exists business_assets_admin_insert on storage.objects;
    create policy business_assets_admin_insert
      on storage.objects
      for insert
      to authenticated
      with check (
        bucket_id = 'business-assets'
        and split_part(name, '/', 1) = 'business'
        and exists (
          select 1
            from public.business_memberships m
           where m.business_id::text = split_part(name, '/', 2)
             and m.user_id = auth.uid()
             and m.role = 'admin'
        )
      );

    drop policy if exists business_assets_admin_update on storage.objects;
    create policy business_assets_admin_update
      on storage.objects
      for update
      to authenticated
      using (
        bucket_id = 'business-assets'
        and split_part(name, '/', 1) = 'business'
        and exists (
          select 1
            from public.business_memberships m
           where m.business_id::text = split_part(name, '/', 2)
             and m.user_id = auth.uid()
             and m.role = 'admin'
        )
      )
      with check (
        bucket_id = 'business-assets'
        and split_part(name, '/', 1) = 'business'
        and exists (
          select 1
            from public.business_memberships m
           where m.business_id::text = split_part(name, '/', 2)
             and m.user_id = auth.uid()
             and m.role = 'admin'
        )
      );

    drop policy if exists business_assets_admin_delete on storage.objects;
    create policy business_assets_admin_delete
      on storage.objects
      for delete
      to authenticated
      using (
        bucket_id = 'business-assets'
        and split_part(name, '/', 1) = 'business'
        and exists (
          select 1
            from public.business_memberships m
           where m.business_id::text = split_part(name, '/', 2)
             and m.user_id = auth.uid()
             and m.role = 'admin'
        )
      );
  end if;
end
$$;

create or replace function public.business_logo_set(
  p_business_id uuid,
  p_logo_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_url text := nullif(btrim(coalesce(p_logo_url, '')), '');
  v_prefix text;
  v_business public.businesses;
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

  if v_url is not null then
    if length(v_url) > 500
       or position('..' in v_url) > 0
       or v_url !~* '^https?://[^/[:space:]]+/storage/v1/object/public/business-assets/'
    then
      raise exception 'invalid_logo_url';
    end if;

    -- La ruta debe pertenecer exactamente a este negocio.
    v_prefix := '/storage/v1/object/public/business-assets/business/'
      || p_business_id::text || '/';

    if position(v_prefix in v_url) = 0 then
      raise exception 'logo_outside_business';
    end if;
  end if;

  update public.businesses
     set logo_url = v_url
   where id = p_business_id;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    case when v_url is null then 'business.logo_removed' else 'business.logo_updated' end,
    'business',
    p_business_id::text,
    jsonb_build_object('logo_url', v_url, 'previous_logo_url', v_business.logo_url)
  );

  return jsonb_build_object(
    'business_id', p_business_id,
    'logo_url', v_url
  );
end;
$$;

grant execute on function public.business_logo_set(uuid, text) to authenticated;
revoke execute on function public.business_logo_set(uuid, text) from anon;
revoke execute on function public.business_logo_set(uuid, text) from public;

do $$
begin
  if not exists (
    select 1 from pg_proc
     where proname = 'business_logo_set'
       and pronamespace = 'public'::regnamespace
  ) then
    raise exception 'falta business_logo_set';
  end if;

  if to_regclass('storage.buckets') is not null then
    if not exists (
      select 1 from storage.buckets where id = 'business-assets'
    ) then
      raise exception 'falta el bucket business-assets';
    end if;
  end if;
end
$$;
