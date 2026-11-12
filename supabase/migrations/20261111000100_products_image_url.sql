-- =====================================================================
-- Loopoint · Foto de productos en la carta (`products.image_url`)
--
--   1. Columna `public.products.image_url` (nullable, formato URL http/https).
--   2. `product_upsert` acepta `p_image_url` opcional y valida que la URL
--      pertenezca al bucket `business-assets` bajo `business/<business_id>/`.
--   3. `products_list` devuelve `image_url` junto con los datos del producto.
-- =====================================================================

alter table public.products
  add column if not exists image_url text;

comment on column public.products.image_url is
  'URL pública de la foto del producto en Storage (bucket business-assets/business/<business_id>/...).';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'products_image_url_format'
       and conrelid = 'public.products'::regclass
  ) then
    alter table public.products
      add constraint products_image_url_format check (
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

drop function if exists public.product_upsert(uuid, integer, text, uuid, text, integer, boolean, text);

create or replace function public.product_upsert(
  p_business_id uuid,
  p_price_cop integer,
  p_name text default '',
  p_id uuid default null,
  p_description text default null,
  p_cost_cop integer default null,
  p_is_active boolean default true,
  p_kind text default 'simple',
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
  v_name text := btrim(coalesce(p_name, ''));
  v_kind text := lower(btrim(coalesce(p_kind, 'simple')));
  v_image_url text := nullif(btrim(coalesce(p_image_url, '')), '');
  v_image_prefix text;
  v_previous_kind text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  if v_kind not in ('simple', 'combo') then
    raise exception 'invalid_product_kind';
  end if;
  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception 'invalid_product_name';
  end if;
  if p_price_cop is null or p_price_cop <= 0 or p_price_cop > 100000000 then
    raise exception 'invalid_product_price';
  end if;
  if p_cost_cop is not null and p_cost_cop < 0 then
    raise exception 'invalid_product_cost';
  end if;

  if v_image_url is not null then
    if length(v_image_url) > 500
       or position('..' in v_image_url) > 0
       or v_image_url ~* '(%2e|%2f|%5c|\\)'
       or v_image_url !~* '^https?://[^/?#@[:space:]]+/storage/v1/object/public/business-assets/[^?#[:space:]]+$'
    then
      raise exception 'invalid_product_image_url';
    end if;

    v_image_prefix := '^https?://[^/?#@[:space:]]+/storage/v1/object/public/business-assets/business/'
      || p_business_id::text || '/[^?#[:space:]]+$';

    if v_image_url !~* v_image_prefix then
      raise exception 'product_image_outside_business';
    end if;
  end if;

  if p_id is null then
    insert into public.products (
      business_id, name, description, price_cop, cost_cop, is_active, kind, image_url
    ) values (
      p_business_id, v_name, btrim(coalesce(p_description, '')),
      p_price_cop, p_cost_cop, p_is_active, v_kind, v_image_url
    )
    returning id into v_id;
  else
    select kind into v_previous_kind
      from public.products
     where id = p_id and business_id = p_business_id
     for update;

    if not found then raise exception 'product_not_found'; end if;

    if v_kind = 'combo' and exists (
      select 1 from public.product_combo_items ci
       where ci.component_product_id = p_id
    ) then
      raise exception 'product_used_in_combo';
    end if;

    update public.products
       set name = v_name,
           description = btrim(coalesce(p_description, '')),
           price_cop = p_price_cop,
           cost_cop = p_cost_cop,
           is_active = p_is_active,
           kind = v_kind,
           image_url = v_image_url,
           updated_at = now()
     where id = p_id and business_id = p_business_id
    returning id into v_id;

    if v_previous_kind = 'combo' and v_kind = 'simple' then
      delete from public.product_combo_items where combo_id = p_id;
    end if;
  end if;

  return (
    select to_jsonb(r) || jsonb_build_object(
      'combo_items', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'product_id', ci.component_product_id,
                 'name', cp.name,
                 'quantity', ci.quantity,
                 'unit_price_cop', cp.price_cop
               ) order by cp.name)
          from public.product_combo_items ci
          join public.products cp on cp.id = ci.component_product_id
         where ci.combo_id = v_id
      ), '[]'::jsonb)
    )
    from public.products r
    where r.id = v_id
  );
end;
$$;

grant execute on function public.product_upsert(
  uuid, integer, text, uuid, text, integer, boolean, text, text
) to authenticated, service_role;
revoke execute on function public.product_upsert(
  uuid, integer, text, uuid, text, integer, boolean, text, text
) from public, anon;

drop function if exists public.products_list(uuid, boolean);

create or replace function public.products_list(
  p_business_id uuid,
  p_only_active boolean default true
)
returns table (
  id uuid,
  name text,
  description text,
  price_cop integer,
  cost_cop integer,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  kind text,
  combo_items jsonb,
  image_url text
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
    select p.id,
           p.name,
           p.description,
           p.price_cop,
           p.cost_cop,
           p.is_active,
           p.created_at,
           p.updated_at,
           p.kind,
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'product_id', ci.component_product_id,
                      'name', cp.name,
                      'quantity', ci.quantity,
                      'unit_price_cop', cp.price_cop
                    ) order by cp.name)
               from public.product_combo_items ci
               join public.products cp on cp.id = ci.component_product_id
              where ci.combo_id = p.id
           ), '[]'::jsonb) as combo_items,
           p.image_url
      from public.products p
     where p.business_id = p_business_id
       and (not p_only_active or p.is_active)
     order by p.name;
end;
$$;

grant execute on function public.products_list(uuid, boolean) to authenticated, service_role;
revoke execute on function public.products_list(uuid, boolean) from public, anon;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'products'
       and column_name = 'image_url'
  ) then
    raise exception 'falta columna products.image_url';
  end if;

  if has_function_privilege(
    'anon',
    'public.product_upsert(uuid, integer, text, uuid, text, integer, boolean, text, text)'::regprocedure,
    'execute'
  ) then
    raise exception 'anon no debe ejecutar product_upsert';
  end if;

  if has_function_privilege(
    'anon',
    'public.products_list(uuid, boolean)'::regprocedure,
    'execute'
  ) then
    raise exception 'anon no debe ejecutar products_list';
  end if;
end
$$;
