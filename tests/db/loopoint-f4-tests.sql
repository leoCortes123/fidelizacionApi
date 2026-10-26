-- =====================================================================
-- Loopoint F4 — Combos, compras con ítems, detalle y métricas
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('60000000-0000-4000-8000-000000000001', 'f4-admin@example.test', '{"full_name":"Ana F4"}'),
  ('60000000-0000-4000-8000-000000000002', 'f4-encargado@example.test', '{"full_name":"Encargado F4"}'),
  ('60000000-0000-4000-8000-000000000003', 'f4-cliente@example.test', '{"full_name":"Cliente F4"}'),
  ('60000000-0000-4000-8000-000000000004', 'f4-cliente2@example.test', '{"full_name":"Cliente Dos F4"}'),
  ('60000000-0000-4000-8000-000000000005', 'f4-ajeno@example.test', '{"full_name":"Admin Ajeno F4"}');

set local role authenticated;
select tests.as_user('60000000-0000-4000-8000-000000000001');

select r->>'business_id' as biz
  from (select public.business_register('Taquería F4', 'taqueria-f4') as r) s \gset

select public.business_membership_create(
  :'biz'::uuid, '60000000-0000-4000-8000-000000000002', 'encargado', false
);
select public.business_membership_create(
  :'biz'::uuid, '60000000-0000-4000-8000-000000000003', 'cliente', false
);
select public.loyalty_program_configure(
  :'biz'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);

-- ---------------------------------------------------------------------
-- 1. Carta: productos simples y combo
-- ---------------------------------------------------------------------
select r->>'id' as taco
  from (select public.product_upsert(
    :'biz'::uuid, 2500, 'Taco de guisado', null, 'Taco individual', 800, true, 'simple'
  ) as r) s \gset
select r->>'id' as drink
  from (select public.product_upsert(
    :'biz'::uuid, 1500, 'Agua fresca', null, 'Vaso 12 oz', 400, true, 'simple'
  ) as r) s \gset
select r->>'id' as combo
  from (select public.product_upsert(
    :'biz'::uuid, 6000, 'Combo enganche', null, 'Dos tacos y agua', 2000, true, 'combo'
  ) as r) s \gset

select tests.assert_eq_text(
  (select kind from public.products where id = :'combo'::uuid),
  'combo',
  'el producto combo conserva su tipo'
);

select public.product_combo_set(
  :'biz'::uuid,
  :'combo'::uuid,
  jsonb_build_array(
    jsonb_build_object('product_id', :'taco'::uuid, 'quantity', 2),
    jsonb_build_object('product_id', :'drink'::uuid, 'quantity', 1)
  )
);

select tests.assert_eq_int(
  (select jsonb_array_length(combo_items)
     from public.products_list(:'biz'::uuid, false)
    where id = :'combo'::uuid),
  2,
  'products_list devuelve los componentes del combo'
);
select tests.assert_eq_text(
  (select kind from public.products_list(:'biz'::uuid, false)
    where id = :'taco'::uuid),
  'simple',
  'products_list devuelve el tipo simple'
);

select tests.expect_error(
  format(
    $$select public.product_combo_set(%L::uuid, %L::uuid, '[]'::jsonb)$$,
    :'biz', :'combo'
  ),
  'invalid_combo_items'
);
select tests.expect_error(
  format(
    $$select public.product_combo_set(%L::uuid, %L::uuid, jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'quantity', 1)))$$,
    :'biz', :'combo', :'combo'
  ),
  'invalid_combo_items'
);
select tests.expect_error(
  format(
    $$select public.product_combo_set(%L::uuid, %L::uuid, jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'quantity', 0)))$$,
    :'biz', :'combo', :'taco'
  ),
  'invalid_combo_quantity'
);

-- Un combo no puede ser componente de otro combo.
select public.product_upsert(
  :'biz'::uuid, 9000, 'Super combo', null, '', 3000, true, 'combo'
);
select tests.expect_error(
  format(
    $$select public.product_combo_set(%L::uuid, (select id from public.products where business_id = %L::uuid and name = 'Super combo'), jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'quantity', 1)))$$,
    :'biz', :'biz', :'combo'
  ),
  'combo_component_must_be_simple'
);

-- Un componente usado no puede convertirse en combo.
select tests.expect_error(
  format(
    $$select public.product_upsert(%L::uuid, 2500, 'Taco de guisado', %L::uuid, '', 800, true, 'combo')$$,
    :'biz', :'taco'
  ),
  'product_used_in_combo'
);

-- Combo de otro negocio: producto inexistente en este negocio.
select tests.as_user('60000000-0000-4000-8000-000000000005');
select r->>'business_id' as other_biz
  from (select public.business_register('Otro F4', 'otro-f4') as r) s \gset
select r->>'id' as other_product
  from (select public.product_upsert(
    :'other_biz'::uuid, 1000, 'Producto ajeno', null, '', 100, true, 'simple'
  ) as r) s \gset

select tests.as_user('60000000-0000-4000-8000-000000000001');
select tests.expect_error(
  format(
    $$select public.product_combo_set(%L::uuid, %L::uuid, jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'quantity', 1)))$$,
    :'biz', :'combo', :'other_product'
  ),
  'product_not_found'
);

-- El encargado no edita la carta.
select tests.as_user('60000000-0000-4000-8000-000000000002');
select tests.expect_error(
  format(
    $$select public.product_upsert(%L::uuid, 1000, 'Producto encargado')$$,
    :'biz'
  ),
  'forbidden'
);

-- ---------------------------------------------------------------------
-- 2. Compra con ítems: suma, validaciones y snapshot
-- ---------------------------------------------------------------------
select tests.as_user('60000000-0000-4000-8000-000000000002');

-- 2 combos (12.000) + 3 tacos (7.500) = 19.500.
select r->>'token' as token, r->>'purchase_id' as purchase,
       jsonb_array_length(r -> 'items') as items_count
  from (
    select public.purchase_qr_create_with_items(
      :'biz'::uuid,
      19500,
      jsonb_build_array(
        jsonb_build_object('product_id', :'combo'::uuid, 'quantity', 2),
        jsonb_build_object('product_id', :'taco'::uuid, 'quantity', 3)
      )
    ) as r
  ) s \gset

select tests.assert_eq_int(:items_count, 2, 'el QR guarda dos líneas');

reset role;
select tests.assert_eq_int(
  (select count(*) from public.purchase_items where purchase_id = :'purchase'::uuid),
  2,
  'purchase_items conserva las líneas'
);
select tests.assert_eq_int(
  (select jsonb_array_length(combo_detail)
     from public.purchase_items
    where purchase_id = :'purchase'::uuid and is_combo),
  2,
  'el detalle del combo guarda sus componentes'
);
select tests.assert_eq_text(
  (select name_snapshot from public.purchase_items
    where purchase_id = :'purchase'::uuid and is_combo),
  'Combo enganche',
  'la línea guarda el nombre del combo'
);
set local role authenticated;
select tests.as_user('60000000-0000-4000-8000-000000000002');

select tests.expect_error(
  format(
    $$select public.purchase_qr_create_with_items(%L::uuid, 10000, jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'quantity', 1)))$$,
    :'biz', :'taco'
  ),
  'purchase_items_total_mismatch'
);
select tests.expect_error(
  format(
    $$select public.purchase_qr_create_with_items(%L::uuid, 2500, jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'quantity', 0)))$$,
    :'biz', :'taco'
  ),
  'invalid_purchase_quantity'
);
select tests.expect_error(
  format(
    $$select public.purchase_qr_create_with_items(%L::uuid, 2500, jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'quantity', 1), jsonb_build_object('product_id', %L::uuid, 'quantity', 1)))$$,
    :'biz', :'taco', :'taco'
  ),
  'invalid_purchase_items'
);
select tests.expect_error(
  format(
    $$select public.purchase_qr_create_with_items(%L::uuid, 1000, jsonb_build_array(jsonb_build_object('product_id', %L::uuid, 'quantity', 1)))$$,
    :'biz', :'other_product'
  ),
  'product_not_found'
);

-- Compra manual sin ítems (compatibilidad).
select r->>'purchase_id' as manual_purchase
  from (select public.purchase_qr_create(:'biz'::uuid, 3000) as r) s \gset
reset role;
select tests.assert_eq_int(
  (select count(*) from public.purchase_items where purchase_id = :'manual_purchase'::uuid),
  0,
  'la compra manual sigue funcionando sin líneas'
);
set local role authenticated;
select tests.as_user('60000000-0000-4000-8000-000000000002');

-- El cliente se afilia y reclama el QR; el detalle usa snapshots.
select tests.as_user('60000000-0000-4000-8000-000000000003');
select public.business_join('taqueria-f4');
select public.purchase_qr_claim(:'token');

-- La vista previa incluye las líneas antes de reclamar otra venta.
select tests.as_user('60000000-0000-4000-8000-000000000002');
select r->>'token' as preview_token
  from (
    select public.purchase_qr_create_with_items(
      :'biz'::uuid,
      6000,
      jsonb_build_array(jsonb_build_object('product_id', :'combo'::uuid, 'quantity', 1))
    ) as r
  ) s \gset

set local role anon;
select tests.assert_eq_int(
  (public.purchase_qr_preview(:'preview_token')->>'items_count')::integer,
  1,
  'la vista previa pública incluye las líneas'
);

set local role authenticated;
select tests.as_user('60000000-0000-4000-8000-000000000001');

-- Cambiar nombre y precio no altera el detalle histórico.
select public.product_upsert(
  :'biz'::uuid, 9900, 'Combo enganche XL', :'combo'::uuid, 'Nuevo', 2500, true, 'combo'
);
select tests.assert_eq_text(
  public.business_purchase_detail(:'biz'::uuid, :'purchase'::uuid)
    -> 'items' -> 0 ->> 'name',
  'Combo enganche',
  'el nombre del ítem es un snapshot'
);
select tests.assert_eq_text(
  (public.business_purchase_detail(:'biz'::uuid, :'purchase'::uuid)
     -> 'items' -> 1 ->> 'name'),
  'Taco de guisado',
  'el detalle conserva los nombres originales'
);

-- ---------------------------------------------------------------------
-- 3. Listado y detalle para el negocio
-- ---------------------------------------------------------------------
select tests.assert_eq_text(
  (select customer_nickname from public.business_purchases_page(
     p_business_id => :'biz'::uuid
   ) where id = :'purchase'::uuid),
  'clientef4',
  'el listado incluye el nickname del cliente'
);
select tests.assert_eq_int(
  (select items_count from public.business_purchases_page(
     p_business_id => :'biz'::uuid
   ) where id = :'purchase'::uuid),
  2,
  'el listado incluye el contador de ítems'
);

select tests.assert_eq_text(
  public.business_purchase_detail(:'biz'::uuid, :'purchase'::uuid)
    -> 'customer' ->> 'nickname',
  'clientef4',
  'el detalle incluye al cliente'
);
select tests.assert_eq_text(
  public.business_purchase_detail(:'biz'::uuid, :'purchase'::uuid)
    -> 'business' ->> 'name',
  'Taquería F4',
  'el detalle incluye el negocio'
);

select tests.as_user('60000000-0000-4000-8000-000000000002');
select tests.assert(
  public.business_purchase_detail(:'biz'::uuid, :'purchase'::uuid) is not null,
  'el encargado ve el detalle de la compra'
);

select tests.as_user('60000000-0000-4000-8000-000000000005');
select tests.expect_error(
  format(
    $$select public.business_purchase_detail(%L::uuid, %L::uuid)$$,
    :'biz', :'purchase'
  ),
  'business_not_found_or_no_access'
);
select tests.expect_error(
  format($$select public.business_purchases_page(%L::uuid)$$, :'biz'),
  'business_not_found_or_no_access'
);

-- ---------------------------------------------------------------------
-- 4. Historial y detalle del cliente
-- ---------------------------------------------------------------------
select tests.as_user('60000000-0000-4000-8000-000000000003');
select tests.assert_eq_int(
  (select items_count from public.my_purchases_page()
    where id = :'purchase'::uuid),
  2,
  'el cliente ve el contador de ítems de su compra'
);
select tests.assert_eq_text(
  public.my_purchase_detail(:'purchase'::uuid)
    -> 'business' ->> 'name',
  'Taquería F4',
  'el cliente ve el negocio en el detalle'
);
select tests.assert_eq_int(
  (public.my_purchase_detail(:'purchase'::uuid) ->> 'items_count')::integer,
  2,
  'el cliente ve las líneas de su compra'
);

select tests.as_user('60000000-0000-4000-8000-000000000004');
select public.business_join('taqueria-f4');
select tests.expect_error(
  format($$select public.my_purchase_detail(%L::uuid)$$, :'purchase'),
  'purchase_not_found'
);

-- ---------------------------------------------------------------------
-- 5. Métricas del Inicio y actividad reciente
-- ---------------------------------------------------------------------
select tests.as_user('60000000-0000-4000-8000-000000000001');
select public.business_dashboard_summary(:'biz'::uuid) as summary \gset

select tests.assert(
  (:'summary'::jsonb ->> 'points_issued_total')::bigint >= 19,
  'las métricas incluyen los loopoints emitidos'
);
select tests.assert(
  (:'summary'::jsonb ->> 'sales_today_cop')::bigint >= 19500,
  'las ventas de hoy cuadran con las compras'
);
select tests.assert(
  (:'summary'::jsonb ->> 'purchases_today')::bigint >= 1,
  'las compras de hoy se cuentan'
);
select tests.assert_eq_int(
  (:'summary'::jsonb ->> 'customers_total')::bigint,
  2,
  'las métricas cuentan los clientes del negocio'
);
select tests.assert_eq_int(
  (:'summary'::jsonb ->> 'pending_qr_count')::bigint,
  2,
  'las métricas cuentan los QR pendientes'
);
select tests.assert(
  (:'summary'::jsonb ->> 'last_activity_at') is not null,
  'las métricas incluyen la última actividad'
);

select tests.assert(
  public.business_recent_activity(:'biz'::uuid, 10) @> jsonb_build_array(
    jsonb_build_object('kind', 'purchase')
  ),
  'la actividad reciente incluye compras'
);

select tests.as_user('60000000-0000-4000-8000-000000000005');
select tests.expect_error(
  format($$select public.business_dashboard_summary(%L::uuid)$$, :'biz'),
  'business_not_found_or_no_access'
);
select tests.expect_error(
  format($$select public.business_recent_activity(%L::uuid, 10)$$, :'biz'),
  'business_not_found_or_no_access'
);

-- ---------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------
reset role;
select tests.assert(
  not has_function_privilege(
    'anon',
    'public.purchase_qr_create_with_items(uuid, integer, jsonb)',
    'execute'
  ),
  'anon no genera ventas con ítems'
);
select tests.assert(
  not has_function_privilege(
    'anon',
    'public.business_dashboard_summary(uuid)',
    'execute'
  ),
  'anon no lee métricas del negocio'
);
select tests.assert(
  has_function_privilege(
    'authenticated',
    'public.my_purchase_detail(uuid)',
    'execute'
  ),
  'el cliente autenticado consulta su detalle'
);

\echo '== Pruebas Loopoint F4 completadas =='
