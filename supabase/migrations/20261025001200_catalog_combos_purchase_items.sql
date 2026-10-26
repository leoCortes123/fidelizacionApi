-- =====================================================================
-- Loopoint F4 · M3 — Carta con combos, compras con ítems y detalle
--
--   1. `products.kind` ('simple' | 'combo') y `product_combo_items`.
--   2. `product_upsert` acepta el tipo; `product_combo_set` reemplaza los
--      componentes (un solo nivel, sin ciclos ni productos de otro negocio).
--   3. `purchase_items` guarda líneas snapshot de cada venta.
--   4. `purchase_qr_create_with_items`; `purchase_qr_create` pasa a ser un
--      wrapper compatible con `[]`.
--   5. `business_purchases_page`, `business_purchase_detail`,
--      `my_purchases_page` y `my_purchase_detail`.
--   6. `purchase_qr_preview` incluye las líneas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tipo de producto y componentes de combo
-- ---------------------------------------------------------------------
alter table public.products
  add column if not exists kind text not null default 'simple';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'products_kind_valid'
       and conrelid = 'public.products'::regclass
  ) then
    alter table public.products
      add constraint products_kind_valid
      check (kind in ('simple', 'combo'));
  end if;
end
$$;

comment on column public.products.kind is
  'simple = producto de la carta; combo = producto con componentes y precio propio.';

create table if not exists public.product_combo_items (
  combo_id uuid not null references public.products (id) on delete cascade,
  component_product_id uuid not null references public.products (id) on delete restrict,
  quantity integer not null default 1,
  created_at timestamptz not null default now(),
  primary key (combo_id, component_product_id),
  constraint product_combo_items_not_self check (combo_id <> component_product_id),
  constraint product_combo_items_quantity check (quantity between 1 and 99)
);

create index if not exists product_combo_items_component_idx
  on public.product_combo_items (component_product_id);

alter table public.product_combo_items enable row level security;
revoke all on public.product_combo_items from anon, authenticated;

comment on table public.product_combo_items is
  'Componentes de un combo. Solo un nivel: los componentes deben ser productos simples.';

-- ---------------------------------------------------------------------
-- 2. Productos: tipo en el upsert y listado con componentes
-- ---------------------------------------------------------------------
drop function if exists public.product_upsert(uuid, integer, text, uuid, text, integer, boolean);

create or replace function public.product_upsert(
  p_business_id uuid,
  p_price_cop integer,
  p_name text default '',
  p_id uuid default null,
  p_description text default null,
  p_cost_cop integer default null,
  p_is_active boolean default true,
  p_kind text default 'simple'
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

  if p_id is null then
    insert into public.products (
      business_id, name, description, price_cop, cost_cop, is_active, kind
    ) values (
      p_business_id, v_name, btrim(coalesce(p_description, '')),
      p_price_cop, p_cost_cop, p_is_active, v_kind
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
  uuid, integer, text, uuid, text, integer, boolean, text
) to authenticated;
revoke execute on function public.product_upsert(
  uuid, integer, text, uuid, text, integer, boolean, text
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
  combo_items jsonb
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
           ), '[]'::jsonb) as combo_items
      from public.products p
     where p.business_id = p_business_id
       and (not p_only_active or p.is_active)
     order by p.name;
end;
$$;

grant execute on function public.products_list(uuid, boolean) to authenticated;
revoke execute on function public.products_list(uuid, boolean) from public, anon;

create or replace function public.product_combo_set(
  p_business_id uuid,
  p_product_id uuid,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_product public.products;
  v_item jsonb;
  v_component public.products;
  v_quantity integer;
  v_seen uuid[] := '{}';
  v_component_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  select * into v_product
    from public.products
   where id = p_product_id and business_id = p_business_id
   for update;

  if not found then raise exception 'product_not_found'; end if;
  if v_product.kind <> 'combo' then raise exception 'product_not_combo'; end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'invalid_combo_items';
  end if;

  delete from public.product_combo_items where combo_id = p_product_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      v_component_id := (v_item ->> 'product_id')::uuid;
    exception
      when others then raise exception 'invalid_combo_items';
    end;

    if v_component_id = p_product_id or v_component_id = any (v_seen) then
      raise exception 'invalid_combo_items';
    end if;
    v_seen := array_append(v_seen, v_component_id);

    if coalesce(v_item ->> 'quantity', '') !~ '^[0-9]{1,2}$' then
      raise exception 'invalid_combo_quantity';
    end if;
    v_quantity := (v_item ->> 'quantity')::integer;
    if v_quantity < 1 or v_quantity > 99 then
      raise exception 'invalid_combo_quantity';
    end if;

    select * into v_component
      from public.products
     where id = v_component_id and business_id = p_business_id;

    if not found then raise exception 'product_not_found'; end if;
    if v_component.kind <> 'simple' then
      raise exception 'combo_component_must_be_simple';
    end if;

    insert into public.product_combo_items (combo_id, component_product_id, quantity)
    values (p_product_id, v_component_id, v_quantity);
  end loop;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'product.combo_updated',
    'product',
    p_product_id::text,
    jsonb_build_object('items', p_items)
  );

  return jsonb_build_object(
    'product_id', p_product_id,
    'kind', 'combo',
    'combo_items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'product_id', ci.component_product_id,
               'name', cp.name,
               'quantity', ci.quantity,
               'unit_price_cop', cp.price_cop
             ) order by cp.name)
        from public.product_combo_items ci
        join public.products cp on cp.id = ci.component_product_id
       where ci.combo_id = p_product_id
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.product_combo_set(uuid, uuid, jsonb) to authenticated;
revoke execute on function public.product_combo_set(uuid, uuid, jsonb) from public, anon;

-- ---------------------------------------------------------------------
-- 3. Líneas snapshot de la compra
-- ---------------------------------------------------------------------
create table if not exists public.purchase_items (
  id uuid primary key default extensions.gen_random_uuid(),
  purchase_id uuid not null references public.purchases (id) on delete cascade,
  product_id uuid references public.products (id) on delete set null,
  name_snapshot text not null,
  unit_price_cop integer not null,
  quantity integer not null,
  line_total_cop integer not null,
  is_combo boolean not null default false,
  combo_detail jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  constraint purchase_items_name_not_blank check (length(btrim(name_snapshot)) > 0),
  constraint purchase_items_price_positive check (unit_price_cop > 0),
  constraint purchase_items_quantity check (quantity between 1 and 99),
  constraint purchase_items_line_total check (line_total_cop > 0)
);

create index if not exists purchase_items_purchase_idx
  on public.purchase_items (purchase_id);

alter table public.purchase_items enable row level security;
revoke all on public.purchase_items from anon, authenticated;

comment on table public.purchase_items is
  'Líneas de la compra con nombre y precio congelados. El detalle no cambia si se edita la carta.';

-- ---------------------------------------------------------------------
-- 4. QR de compra con ítems
-- ---------------------------------------------------------------------
create or replace function public.purchase_qr_create_with_items(
  p_business_id uuid,
  p_amount_cop integer,
  p_items jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_business public.businesses;
  v_program public.loyalty_programs;
  v_campaign public.loyalty_campaigns;
  v_token text;
  v_purchase_id uuid;
  v_expires_at timestamptz;
  v_base_points integer;
  v_points_preview integer := 0;
  v_item jsonb;
  v_product public.products;
  v_component_id uuid;
  v_quantity integer;
  v_line_total integer;
  v_total integer := 0;
  v_items jsonb := '[]'::jsonb;
  v_combo_detail jsonb;
  v_seen uuid[] := '{}';
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  select * into v_business
    from public.businesses
   where id = p_business_id and is_active;

  if not found then raise exception 'business_not_found'; end if;

  if p_amount_cop is null or p_amount_cop <= 0 then
    raise exception 'amount_invalid';
  end if;
  if p_amount_cop > 50000000 then
    raise exception 'amount_too_large';
  end if;

  -- Ítems: se normalizan antes de crear la venta para no dejar residuos.
  if p_items is not null and jsonb_typeof(p_items) <> 'array' then
    raise exception 'invalid_purchase_items';
  end if;

  if p_items is not null and jsonb_array_length(p_items) > 0 then
    for v_item in select * from jsonb_array_elements(p_items) loop
      begin
        v_component_id := (v_item ->> 'product_id')::uuid;
      exception
        when others then raise exception 'invalid_purchase_items';
      end;

      if v_component_id = any (v_seen) then
        raise exception 'invalid_purchase_items';
      end if;
      v_seen := array_append(v_seen, v_component_id);

      if coalesce(v_item ->> 'quantity', '') !~ '^[0-9]{1,2}$' then
        raise exception 'invalid_purchase_quantity';
      end if;
      v_quantity := (v_item ->> 'quantity')::integer;
      if v_quantity < 1 or v_quantity > 99 then
        raise exception 'invalid_purchase_quantity';
      end if;

      select * into v_product
        from public.products
       where id = v_component_id
         and business_id = p_business_id
         and is_active;

      if not found then raise exception 'product_not_found'; end if;

      v_line_total := v_product.price_cop * v_quantity;
      v_total := v_total + v_line_total;

      if v_product.kind = 'combo' then
        select coalesce(jsonb_agg(jsonb_build_object(
                 'product_id', ci.component_product_id,
                 'name', cp.name,
                 'quantity', ci.quantity,
                 'unit_price_cop', cp.price_cop
               ) order by cp.name), '[]'::jsonb)
          into v_combo_detail
          from public.product_combo_items ci
          join public.products cp on cp.id = ci.component_product_id
         where ci.combo_id = v_product.id;
      else
        v_combo_detail := '[]'::jsonb;
      end if;

      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'product_id', v_product.id,
        'name', v_product.name,
        'unit_price_cop', v_product.price_cop,
        'quantity', v_quantity,
        'line_total_cop', v_line_total,
        'is_combo', v_product.kind = 'combo',
        'combo_detail', v_combo_detail
      ));
    end loop;

    if v_total <> p_amount_cop then
      raise exception 'purchase_items_total_mismatch';
    end if;
  end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found or not v_program.is_active then
    raise exception 'program_not_active';
  end if;

  v_base_points := floor(p_amount_cop::numeric / v_program.cop_per_point_unit)::integer;

  select * into v_campaign
    from public.loyalty_campaigns c
   where c.business_id = p_business_id
     and c.is_active
     and c.valid_from <= now()
     and (c.valid_until is null or c.valid_until > now())
     and p_amount_cop >= c.min_purchase_amount
   order by c.multiplier desc, c.bonus_points desc, c.created_at desc
   limit 1;

  if found then
    v_points_preview := floor(v_base_points * greatest(coalesce(v_campaign.multiplier, 1), 1))::integer
                        + greatest(coalesce(v_campaign.bonus_points, 0), 0);
  else
    v_points_preview := v_base_points;
  end if;
  v_points_preview := least(greatest(v_points_preview, 0), 1000000);

  perform private.consume_rate_limit('purchase_qr_create:' || v_uid::text, 60, 60);

  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_expires_at := now() + make_interval(hours => v_program.qr_expiry_hours);

  insert into public.purchases (
    business_id, amount_cop, registrar_id, token_hash, expires_at, settings_snapshot
  ) values (
    p_business_id,
    p_amount_cop,
    v_uid,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    v_expires_at,
    jsonb_build_object(
      'cop_per_point_unit', v_program.cop_per_point_unit,
      'qr_expiry_hours', v_program.qr_expiry_hours,
      'points_expiry_days', v_program.points_expiry_days,
      'program_updated_at', v_program.updated_at
    )
  )
  returning id into v_purchase_id;

  if jsonb_array_length(v_items) > 0 then
    insert into public.purchase_items (
      purchase_id, product_id, name_snapshot, unit_price_cop, quantity,
      line_total_cop, is_combo, combo_detail
    )
    select
      v_purchase_id,
      (i ->> 'product_id')::uuid,
      i ->> 'name',
      (i ->> 'unit_price_cop')::integer,
      (i ->> 'quantity')::integer,
      (i ->> 'line_total_cop')::integer,
      (i ->> 'is_combo')::boolean,
      coalesce(i -> 'combo_detail', '[]'::jsonb)
    from jsonb_array_elements(v_items) i;
  end if;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'purchase.qr_created',
    'purchase',
    v_purchase_id::text,
    jsonb_build_object(
      'amount_cop', p_amount_cop,
      'points_preview', v_points_preview,
      'expires_at', v_expires_at,
      'items_count', jsonb_array_length(v_items)
    )
  );

  return jsonb_build_object(
    'purchase_id', v_purchase_id,
    'token', v_token,
    'business_id', v_business.id,
    'business_name', v_business.name,
    'amount_cop', p_amount_cop,
    'points_preview', v_points_preview,
    'expires_at', v_expires_at,
    'status', 'pending_claim',
    'items', v_items
  );
end;
$$;

grant execute on function public.purchase_qr_create_with_items(uuid, integer, jsonb)
  to authenticated;
revoke execute on function public.purchase_qr_create_with_items(uuid, integer, jsonb)
  from public, anon;

create or replace function public.purchase_qr_create(
  p_business_id uuid,
  p_amount_cop integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return public.purchase_qr_create_with_items(
    p_business_id,
    p_amount_cop,
    '[]'::jsonb
  );
end;
$$;

grant execute on function public.purchase_qr_create(uuid, integer) to authenticated;
revoke execute on function public.purchase_qr_create(uuid, integer) from public, anon;

-- ---------------------------------------------------------------------
-- 5. Vista previa pública con las líneas de la venta
-- ---------------------------------------------------------------------
create or replace function public.purchase_qr_preview(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_purchase public.purchases;
  v_business public.businesses;
  v_program public.loyalty_programs;
  v_campaign public.loyalty_campaigns;
  v_points integer;
  v_status public.purchase_status;
  v_items jsonb;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  perform private.consume_rate_limit(
    'purchase_qr_preview:' || left(encode(extensions.digest(p_token, 'sha256'), 'hex'), 24),
    60, 60
  );

  select * into v_purchase
    from public.purchases
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and business_id is not null;

  if not found then raise exception 'invalid_token'; end if;

  select * into v_business
    from public.businesses
   where id = v_purchase.business_id;

  select * into v_program
    from public.loyalty_programs
   where business_id = v_purchase.business_id;

  v_status := v_purchase.status;
  if v_status = 'pending_claim' and v_purchase.expires_at <= now() then
    v_status := 'expired';
  end if;

  if v_status = 'pending_claim' and v_program.id is not null then
    select * into v_campaign
      from public.loyalty_campaigns c
     where c.business_id = v_purchase.business_id
       and c.is_active
       and c.valid_from <= now()
       and (c.valid_until is null or c.valid_until > now())
       and v_purchase.amount_cop >= c.min_purchase_amount
     order by c.multiplier desc, c.bonus_points desc, c.created_at desc
     limit 1;

    v_points := floor(v_purchase.amount_cop::numeric / v_program.cop_per_point_unit)::integer;
    if v_campaign.id is not null then
      v_points := floor(v_points * greatest(coalesce(v_campaign.multiplier, 1), 1))::integer
                  + greatest(coalesce(v_campaign.bonus_points, 0), 0);
    end if;
    v_points := least(greatest(v_points, 0), 1000000);
  else
    v_points := v_purchase.points_awarded;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', pi.id,
           'name', pi.name_snapshot,
           'quantity', pi.quantity,
           'unit_price_cop', pi.unit_price_cop,
           'line_total_cop', pi.line_total_cop,
           'is_combo', pi.is_combo,
           'combo_detail', pi.combo_detail
         ) order by pi.created_at), '[]'::jsonb)
    into v_items
    from public.purchase_items pi
   where pi.purchase_id = v_purchase.id;

  return jsonb_build_object(
    'purchase_id', v_purchase.id,
    'business_id', v_purchase.business_id,
    'business_name', coalesce(v_business.name, 'Negocio'),
    'business_slug', v_business.slug,
    'business_logo_url', v_business.logo_url,
    'amount_cop', v_purchase.amount_cop,
    'points_preview', v_points,
    'status', v_status,
    'claimed', v_status = 'claimed',
    'expires_at', v_purchase.expires_at,
    'items', v_items,
    'items_count', jsonb_array_length(v_items)
  );
end;
$$;

revoke execute on function public.purchase_qr_preview(text) from public;
grant execute on function public.purchase_qr_preview(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Compras del negocio con contador de ítems y nickname
-- ---------------------------------------------------------------------
create or replace function public.business_purchases_page(
  p_business_id uuid,
  p_limit integer default 20,
  p_offset integer default 0,
  p_status public.purchase_status default null
)
returns table (
  id uuid,
  amount_cop integer,
  status public.purchase_status,
  points_awarded integer,
  created_at timestamptz,
  expires_at timestamptz,
  claimed_at timestamptz,
  customer_name text,
  customer_nickname text,
  customer_email text,
  registrar_name text,
  items_count integer,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  return query
    select p.id,
           p.amount_cop,
           p.status,
           p.points_awarded,
           p.created_at,
           p.expires_at,
           p.claimed_at,
           customer.full_name,
           customer.nickname,
           customer.email,
           registrar.full_name,
           (select count(*)::integer from public.purchase_items pi
             where pi.purchase_id = p.id),
           count(*) over ()
      from public.purchases p
      left join public.profiles customer on customer.id = p.claimed_by
      left join public.profiles registrar on registrar.id = p.registrar_id
     where p.business_id = p_business_id
       and (p_status is null or p.status = p_status)
     order by p.created_at desc
     limit v_limit offset v_offset;
end;
$$;

grant execute on function public.business_purchases_page(
  uuid, integer, integer, public.purchase_status
) to authenticated;
revoke execute on function public.business_purchases_page(
  uuid, integer, integer, public.purchase_status
) from public, anon;

create or replace function public.business_purchase_detail(
  p_business_id uuid,
  p_purchase_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_purchase public.purchases;
  v_business public.businesses;
  v_items jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  select * into v_purchase
    from public.purchases
   where id = p_purchase_id and business_id = p_business_id;

  if not found then raise exception 'purchase_not_found'; end if;

  select * into v_business from public.businesses where id = p_business_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', pi.id,
           'product_id', pi.product_id,
           'name', pi.name_snapshot,
           'quantity', pi.quantity,
           'unit_price_cop', pi.unit_price_cop,
           'line_total_cop', pi.line_total_cop,
           'is_combo', pi.is_combo,
           'combo_detail', pi.combo_detail
         ) order by pi.created_at), '[]'::jsonb)
    into v_items
    from public.purchase_items pi
   where pi.purchase_id = p_purchase_id;

  return jsonb_build_object(
    'purchase', jsonb_build_object(
      'id', v_purchase.id,
      'business_id', v_purchase.business_id,
      'amount_cop', v_purchase.amount_cop,
      'status', v_purchase.status,
      'points_awarded', v_purchase.points_awarded,
      'created_at', v_purchase.created_at,
      'expires_at', v_purchase.expires_at,
      'claimed_at', v_purchase.claimed_at,
      'cancelled_at', v_purchase.cancelled_at,
      'cancellation_reason', v_purchase.cancellation_reason
    ),
    'business', jsonb_build_object(
      'id', v_business.id,
      'name', v_business.name,
      'slug', v_business.slug,
      'logo_url', v_business.logo_url
    ),
    'customer', (
      select jsonb_build_object(
        'id', pr.id, 'full_name', pr.full_name,
        'nickname', pr.nickname, 'email', pr.email
      )
      from public.profiles pr where pr.id = v_purchase.claimed_by
    ),
    'registrar', (
      select jsonb_build_object(
        'id', pr.id, 'full_name', pr.full_name, 'email', pr.email
      )
      from public.profiles pr where pr.id = v_purchase.registrar_id
    ),
    'items', v_items,
    'items_count', jsonb_array_length(v_items)
  );
end;
$$;

grant execute on function public.business_purchase_detail(uuid, uuid) to authenticated;
revoke execute on function public.business_purchase_detail(uuid, uuid) from public, anon;

-- ---------------------------------------------------------------------
-- 7. Compras del cliente (multi-negocio) y su detalle
-- ---------------------------------------------------------------------
create or replace function public.my_purchases_page(
  p_business_id uuid default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns table (
  id uuid,
  business_id uuid,
  business_name text,
  business_slug text,
  business_logo_url text,
  amount_cop integer,
  points_awarded integer,
  claimed_at timestamptz,
  created_at timestamptz,
  items_count integer,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  return query
    select p.id,
           p.business_id,
           b.name,
           b.slug,
           b.logo_url,
           p.amount_cop,
           p.points_awarded,
           p.claimed_at,
           p.created_at,
           (select count(*)::integer from public.purchase_items pi
             where pi.purchase_id = p.id),
           count(*) over ()
      from public.purchases p
      join public.businesses b on b.id = p.business_id
     where p.claimed_by = v_uid
       and p.status = 'claimed'
       and (p_business_id is null or p.business_id = p_business_id)
     order by p.claimed_at desc nulls last, p.created_at desc
     limit v_limit offset v_offset;
end;
$$;

grant execute on function public.my_purchases_page(uuid, integer, integer) to authenticated;
revoke execute on function public.my_purchases_page(uuid, integer, integer) from public, anon;

create or replace function public.my_purchase_detail(p_purchase_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_purchase public.purchases;
  v_business public.businesses;
  v_items jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_purchase
    from public.purchases
   where id = p_purchase_id
     and claimed_by = v_uid
     and status = 'claimed';

  if not found then raise exception 'purchase_not_found'; end if;

  select * into v_business from public.businesses where id = v_purchase.business_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', pi.id,
           'product_id', pi.product_id,
           'name', pi.name_snapshot,
           'quantity', pi.quantity,
           'unit_price_cop', pi.unit_price_cop,
           'line_total_cop', pi.line_total_cop,
           'is_combo', pi.is_combo,
           'combo_detail', pi.combo_detail
         ) order by pi.created_at), '[]'::jsonb)
    into v_items
    from public.purchase_items pi
   where pi.purchase_id = p_purchase_id;

  return jsonb_build_object(
    'purchase', jsonb_build_object(
      'id', v_purchase.id,
      'business_id', v_purchase.business_id,
      'amount_cop', v_purchase.amount_cop,
      'status', v_purchase.status,
      'points_awarded', v_purchase.points_awarded,
      'created_at', v_purchase.created_at,
      'claimed_at', v_purchase.claimed_at
    ),
    'business', jsonb_build_object(
      'id', v_business.id,
      'name', v_business.name,
      'slug', v_business.slug,
      'logo_url', v_business.logo_url
    ),
    'items', v_items,
    'items_count', jsonb_array_length(v_items)
  );
end;
$$;

grant execute on function public.my_purchase_detail(uuid) to authenticated;
revoke execute on function public.my_purchase_detail(uuid) from public, anon;

-- ---------------------------------------------------------------------
-- 8. Índices de apoyo
-- ---------------------------------------------------------------------
create index if not exists purchases_claimed_business_idx
  on public.purchases (claimed_by, business_id, claimed_at desc);

create index if not exists purchases_business_status_created_idx
  on public.purchases (business_id, status, created_at desc);

-- ---------------------------------------------------------------------
-- 9. Comprobaciones
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'products'
       and column_name = 'kind'
  ) then
    raise exception 'products.kind no existe';
  end if;

  if to_regclass('public.purchase_items') is null then
    raise exception 'purchase_items no existe';
  end if;

  if not exists (
    select 1 from pg_proc
     where proname = 'purchase_qr_create_with_items'
       and pronamespace = 'public'::regnamespace
  ) then
    raise exception 'falta purchase_qr_create_with_items';
  end if;
end
$$;
