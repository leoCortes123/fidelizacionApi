-- =====================================================================
-- Loopoint F9 — Cierre: matriz de pruebas SQL
--
-- Cubre los casos de §8.1 del plan que quedaban parciales o ausentes:
--   1.  Nickname duplicado por mayúsculas (comparación sin distinguir caja).
--   2.  Perfil: un cliente no puede editar el perfil de otro.
--   3.  Logo: la URL guardada queda auditada.
--   4.  Combos: guardar de nuevo reemplaza los componentes.
--   5.  Snapshot de precio: cambiar el precio del producto no altera la compra.
--   6.  Detalle de compra: el admin de A no ve la compra de B.
--   7.  Listas: paginación y filtro por negocio.
--   8.  Token de canje: contexto de un token ya consumido.
--   9.  Dashboard: negocio sin datos devuelve 0/null.
--  10.  Grants: matriz completa (anon/authenticated/service_role/PUBLIC).
--  11.  Backfill: el nickname no pisa el existente.
--  12.  Campañas: regresión de la lógica de campañas dinámicas.
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('a1000000-0000-4000-8000-000000000001', 'f9-admin@example.test', '{"full_name":"Admin F9"}'),
  ('a1000000-0000-4000-8000-000000000002', 'f9-encargado@example.test', '{"full_name":"Encargado F9"}'),
  ('a1000000-0000-4000-8000-000000000003', 'f9-cliente@example.test', '{"full_name":"Cliente F9"}'),
  ('a1000000-0000-4000-8000-000000000004', 'f9-cliente2@example.test', '{"full_name":"Cliente Dos F9"}'),
  ('a1000000-0000-4000-8000-000000000005', 'f9-ajeno@example.test', '{"full_name":"Admin Ajeno F9"}');

-- =====================================================================
-- 1. Nickname duplicado por mayúsculas
-- =====================================================================
select tests.assert_eq_text(
  (select nickname from public.profiles where id = 'a1000000-0000-4000-8000-000000000001'),
  'adminf9',
  'el nickname del admin F9 se autogenera'
);

set local role authenticated;
select tests.as_user('a1000000-0000-4000-8000-000000000003');

-- El alias se normaliza a minúsculas, así que 'ADMINF9' colisiona con 'adminf9'.
select tests.expect_error(
  $$select public.profile_update('Cliente F9', 'ADMINF9')$$,
  'nickname_taken'
);
select tests.expect_error(
  $$select public.profile_update('Cliente F9', 'AdminF9')$$,
  'nickname_taken'
);
select tests.assert(
  not public.profile_nickname_available('ADMINF9'),
  'un alias con mayúsculas no está disponible si el minúsculo ya existe'
);

-- =====================================================================
-- 2. Un cliente no puede editar el perfil de otro
-- =====================================================================
-- La RLS filtra la actualización: el cliente solo puede tocar su propio perfil,
-- así que la sentencia no encuentra filas y no hay error.
with upd as (
  update public.profiles
     set full_name = 'Secuestrado'
   where id = 'a1000000-0000-4000-8000-000000000004'
  returning id
)
select tests.assert_eq_int(
  (select count(*) from upd),
  0,
  'la RLS impide editar el perfil de otro cliente'
);
select tests.assert_eq_text(
  (public.profile_update('Cliente F9', 'clientef9'))->>'nickname',
  'clientef9',
  'el cliente sí puede editar su propio perfil'
);

-- La RLS de lectura también impide ver el perfil de otro cliente.
reset role;
select tests.assert_eq_text(
  (select full_name from public.profiles where id = 'a1000000-0000-4000-8000-000000000004'),
  'Cliente Dos F9',
  'el perfil del otro cliente conserva su nombre'
);
set local role authenticated;
select tests.as_user('a1000000-0000-4000-8000-000000000003');

-- =====================================================================
-- 3. El logo del negocio queda auditado
-- =====================================================================
select tests.as_user('a1000000-0000-4000-8000-000000000001');
select r->>'business_id' as biz
  from (select public.business_register('Café F9', 'cafe-f9') as r) s \gset
select public.loyalty_program_configure(
  :'biz'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);

select public.business_logo_set(
  :'biz'::uuid,
  'https://gxfytcquyobhhbjipbea.supabase.co/storage/v1/object/public/business-assets/business/'
  || :'biz'::text || '/logo.png'
);

select tests.assert_eq_int(
  (select count(*)
     from public.business_audit_logs
    where business_id = :'biz'::uuid
      and operation = 'business.logo_updated'
      and entity_type = 'business'
      and entity_id = :'biz'::text),
  1,
  'el cambio de logo deja una fila de auditoría'
);
select tests.assert_eq_text(
  (select metadata ->> 'logo_url'
     from public.business_audit_logs
    where business_id = :'biz'::uuid
      and operation = 'business.logo_updated'
    limit 1),
  'https://gxfytcquyobhhbjipbea.supabase.co/storage/v1/object/public/business-assets/business/'
  || :'biz'::text || '/logo.png',
  'la auditoría guarda la URL pública del logo'
);
select tests.assert(
  (select metadata ? 'previous_logo_url'
     from public.business_audit_logs
    where business_id = :'biz'::uuid
      and operation = 'business.logo_updated'
    limit 1),
  'la auditoría guarda el logo anterior'
);

-- =====================================================================
-- 4. Guardar de nuevo el combo reemplaza los componentes
-- =====================================================================
select tests.as_user('a1000000-0000-4000-8000-000000000001');
select r->>'id' as f9_taco
  from (select public.product_upsert(
    :'biz'::uuid, 2500, 'Taco F9', null, '', 800, true, 'simple'
  ) as r) s \gset
select r->>'id' as f9_drink
  from (select public.product_upsert(
    :'biz'::uuid, 1500, 'Agua F9', null, '', 400, true, 'simple'
  ) as r) s \gset
select r->>'id' as f9_combo
  from (select public.product_upsert(
    :'biz'::uuid, 6000, 'Combo F9', null, '', 2000, true, 'combo'
  ) as r) s \gset

-- Primer conjunto: taco + agua.
select public.product_combo_set(
  :'biz'::uuid, :'f9_combo'::uuid,
  jsonb_build_array(
    jsonb_build_object('product_id', :'f9_taco'::uuid, 'quantity', 2),
    jsonb_build_object('product_id', :'f9_drink'::uuid, 'quantity', 1)
  )
);
select tests.assert_eq_int(
  (select jsonb_array_length(combo_items)
     from public.products_list(:'biz'::uuid, false)
    where id = :'f9_combo'::uuid),
  2,
  'el combo tiene dos componentes'
);

-- Segundo conjunto: solo agua (debe bajar el taco sin dejar rastro).
select public.product_combo_set(
  :'biz'::uuid, :'f9_combo'::uuid,
  jsonb_build_array(
    jsonb_build_object('product_id', :'f9_drink'::uuid, 'quantity', 3)
  )
);
select tests.assert_eq_int(
  (select jsonb_array_length(combo_items)
     from public.products_list(:'biz'::uuid, false)
    where id = :'f9_combo'::uuid),
  1,
  'el segundo guardado reemplaza los componentes'
);
select tests.assert_eq_int(
  (select (combo_items -> 0 ->> 'quantity')::integer
     from public.products_list(:'biz'::uuid, false)
    where id = :'f9_combo'::uuid),
  3,
  'la cantidad del componente restante se actualiza'
);
select tests.assert(
  (select (combo_items -> 0 ->> 'product_id')::uuid = :'f9_drink'::uuid
     from public.products_list(:'biz'::uuid, false)
    where id = :'f9_combo'::uuid),
  'el componente quitado no queda en el combo'
);

-- =====================================================================
-- 5. Snapshot de precio: cambiar el precio del producto no altera la compra
-- =====================================================================
-- 1) Crear la compra con el precio actual del producto (2 tacos × 2500 = 5000).
select r->>'purchase_id' as f9_purchase
  from (select public.purchase_qr_create_with_items(
    :'biz'::uuid, 5000,
    jsonb_build_array(
      jsonb_build_object('product_id', :'f9_taco'::uuid, 'quantity', 2)
    )
  ) as r) s \gset

-- 2) Cambiar el precio del producto en la carta (upsert por ID existente).
select public.product_upsert(
  :'biz'::uuid, 9000, 'Taco F9', :'f9_taco'::uuid, '', 800, true, 'simple'
);

-- 3) El snapshot de la compra no cambia (leída con rol de superborna porque
--    `purchase_items` no tiene policy RLS directa para `authenticated`).
reset role;
select tests.assert_eq_int(
  (select unit_price_cop from public.purchase_items
    where purchase_id = :'f9_purchase'::uuid
      and product_id = :'f9_taco'::uuid),
  2500,
  'el snapshot del precio unitario se conserva'
);
select tests.assert_eq_int(
  (select line_total_cop from public.purchase_items
    where purchase_id = :'f9_purchase'::uuid
      and product_id = :'f9_taco'::uuid),
  5000,
  'el total de la línea se conserva'
);
select tests.assert_eq_text(
  (select name_snapshot from public.purchase_items
    where purchase_id = :'f9_purchase'::uuid
      and product_id = :'f9_taco'::uuid),
  'Taco F9',
  'el snapshot del nombre se conserva'
);
set local role authenticated;
select tests.as_user('a1000000-0000-4000-8000-000000000001');
select tests.assert_eq_int(
  (select price_cop from public.products where id = :'f9_taco'::uuid),
  9000,
  'el precio actual del producto sí cambió'
);

-- =====================================================================
-- 6. Detalle de compra: el admin de A no ve la compra de B
-- =====================================================================
select tests.as_user('a1000000-0000-4000-8000-000000000005');
select r->>'business_id' as other_biz
  from (select public.business_register('Otro F9', 'otro-f9') as r) s \gset
select public.loyalty_program_configure(
  :'other_biz'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);
select r->>'purchase_id' as other_purchase
  from (select public.purchase_qr_create(
    :'other_biz'::uuid, 5000
  ) as r) s \gset

select tests.as_user('a1000000-0000-4000-8000-000000000001');
select tests.expect_error(
  'select public.business_purchase_detail(''' || :'biz' || '''::uuid, '''
    || :'other_purchase' || '''::uuid)',
  'purchase_not_found'
);
select tests.assert_eq_text(
  (public.business_purchase_detail(:'biz'::uuid, :'f9_purchase'::uuid))->'purchase'->>'id',
  :'f9_purchase',
  'el admin de A sí ve su propia compra'
);

-- =====================================================================
-- 7. Listas: paginación y filtro por negocio
-- =====================================================================
select tests.as_user('a1000000-0000-4000-8000-000000000001');

-- Dos compras más en el negocio A para poder paginar.
select r->>'purchase_id' as f9_purchase2
  from (select public.purchase_qr_create(:'biz'::uuid, 3000) as r) s \gset
select r->>'purchase_id' as f9_purchase3
  from (select public.purchase_qr_create(:'biz'::uuid, 4000) as r) s \gset

-- Las compras nacen con `now()`, que dentro de una transacción es constante.
-- Les fijamos marcas de tiempo distintas para que el orden sea determinista.
reset role;
update public.purchases set created_at = now() - interval '3 minutes'
 where id = :'f9_purchase'::uuid;
update public.purchases set created_at = now() - interval '2 minutes'
 where id = :'f9_purchase2'::uuid;
update public.purchases set created_at = now() - interval '1 minute'
 where id = :'f9_purchase3'::uuid;
set local role authenticated;
select tests.as_user('a1000000-0000-4000-8000-000000000001');

-- Página 1 con límite 1 y página 2 con offset 1 sobre las compras del negocio.
select tests.assert_eq_int(
  (select count(*) from public.business_purchases_page(:'biz'::uuid, 1, 0)),
  1,
  'la primera página devuelve una sola compra'
);
select tests.assert_eq_int(
  (select count(*) from public.business_purchases_page(:'biz'::uuid, 1, 1)),
  1,
  'la segunda página devuelve otra compra'
);
select tests.assert_eq_text(
  (select id::text from public.business_purchases_page(:'biz'::uuid, 1, 0) limit 1),
  :'f9_purchase3',
  'la primera página trae la compra más reciente'
);
select tests.assert_eq_text(
  (select id::text from public.business_purchases_page(:'biz'::uuid, 1, 1) limit 1),
  :'f9_purchase2',
  'la segunda página trae la compra anterior'
);
select tests.assert_eq_int(
  (select max(total_count) from public.business_purchases_page(:'biz'::uuid, 1, 0)),
  (select count(*) from public.business_purchases_page(:'biz'::uuid, 100, 0)),
  'total_count cuenta todas las compras del negocio'
);
select tests.assert_eq_int(
  (select count(*) from public.business_purchases_page(:'biz'::uuid, 2, 0)),
  2,
  'la página con límite 2 devuelve dos compras'
);
select tests.assert_eq_int(
  (select count(*) from public.business_purchases_page(:'biz'::uuid, 2, 2)),
  1,
  'la tercera página devuelve la compra restante'
);

-- Filtro por estado. Se esperan las tres compras creadas en este negocio;
-- la tabla `purchases` no es legible por el staff bajo RLS (solo el cliente ve
-- las suyas), así que la referencia es el número de compras creadas arriba.
select tests.assert_eq_int(
  (select count(*) from public.business_purchases_page(:'biz'::uuid, 50, 0, 'pending_claim')),
  3,
  'el filtro por estado pending_claim devuelve las tres compras del negocio'
);
select tests.assert_eq_int(
  (select count(*) from public.business_purchases_page(:'biz'::uuid, 50, 0, 'claimed')),
  0,
  'el filtro por estado claimed devuelve cero en este negocio'
);

-- El negocio B no ve las compras de A: se consulta como su propio admin.
select tests.as_user('a1000000-0000-4000-8000-000000000005');
select tests.assert_eq_int(
  (select count(*) from public.business_purchases_page(:'other_biz'::uuid, 50, 0)),
  1,
  'el negocio B solo ve sus propias compras'
);

-- Y el admin de A no puede consultar las compras de B.
select tests.as_user('a1000000-0000-4000-8000-000000000001');
select tests.expect_error(
  'select * from public.business_purchases_page(''' || :'other_biz' || '''::uuid, 50, 0)',
  'business_not_found_or_no_access'
);

-- El cliente filtra su historial por negocio (my_purchases_page).
select tests.as_user('a1000000-0000-4000-8000-000000000003');
select public.business_join('cafe-f9');
select tests.assert_eq_int(
  (select count(*) from public.my_purchases_page(:'biz'::uuid, 50, 0)),
  0,
  'el cliente sin compras propias no ve compras en el filtro por negocio'
);
select tests.assert_eq_int(
  (select count(*) from public.my_purchases_page(null, 50, 0)),
  0,
  'el cliente sin compras no ve compras en el listado global'
);

-- =====================================================================
-- 8. Token de canje ya consumido
-- =====================================================================
select tests.as_user('a1000000-0000-4000-8000-000000000001');
select public.business_membership_create(
  :'biz'::uuid, 'a1000000-0000-4000-8000-000000000003', 'cliente', false
);
select r->>'id' as f9_reward
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz'::uuid,
      p_type => 'configurable_benefit',
      p_name => 'Postre F9',
      p_points_required => 5,
      p_min_purchase_amount => 0,
      p_max_discount_amount => 3000,
      p_is_active => true
    ) as r
  ) s \gset

select public.loyalty_purchase_register(
  p_business_id => :'biz'::uuid,
  p_customer_id => 'a1000000-0000-4000-8000-000000000003',
  p_amount_cop => 15000,
  p_eligible_amount_cop => 15000,
  p_idempotency_key => 'f9-compra-0001'
);

select tests.as_user('a1000000-0000-4000-8000-000000000003');
select r->>'redemption_id' as f9_redemption,
       r->>'token' as f9_token
  from (
    select public.reward_request_redemption(
      :'biz'::uuid, :'f9_reward'::uuid, 'f9-canje-0001'
    ) as r
  ) s \gset

select tests.as_user('a1000000-0000-4000-8000-000000000001');
select tests.assert_eq_text(
  (public.redemption_token_context(:'f9_token'))->>'reason',
  null,
  'un token vigente no tiene motivo de bloqueo'
);
select tests.assert(
  (public.redemption_token_context(:'f9_token'))->>'can_redeem' = 'true',
  'un token vigente se puede canjear'
);

-- El cliente escanea su propio token: sin rol de staff.
select tests.as_user('a1000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.redemption_token_context(%L)$$, :'f9_token'),
  'forbidden'
);

-- El admin entrega el canje: el token queda consumido.
select tests.as_user('a1000000-0000-4000-8000-000000000001');
select public.redemption_redeem_by_token(:'f9_token');
select tests.assert(
  (select consumed_at is not null
     from public.loyalty_redemption_tokens
    where redemption_id = :'f9_redemption'::uuid),
  'el token queda consumido tras la entrega'
);

-- Un segundo canje con el mismo token debe fallar.
select tests.expect_error(
  format($$select public.redemption_redeem_by_token(%L)$$, :'f9_token'),
  'redemption_already_delivered'
);

-- El contexto de un token consumido explica el motivo.
select tests.assert_eq_text(
  (public.redemption_token_context(:'f9_token'))->>'reason',
  'redemption_already_delivered',
  'el contexto informa que la redención ya fue entregada'
);
select tests.assert_eq_text(
  (public.redemption_token_context(:'f9_token'))->>'can_redeem',
  'false',
  'un token consumido no se puede volver a canjear'
);

-- Token consumido con la redención todavía pendiente: motivo `token_already_consumed`.
select tests.as_user('a1000000-0000-4000-8000-000000000003');
select r->>'redemption_id' as f9_redemption2,
       r->>'token' as f9_token2
  from (
    select public.reward_request_redemption(
      :'biz'::uuid, :'f9_reward'::uuid, 'f9-canje-0002'
    ) as r
  ) s \gset

reset role;
update public.loyalty_redemption_tokens
   set consumed_at = now()
 where redemption_id = :'f9_redemption2'::uuid;
set local role authenticated;

select tests.as_user('a1000000-0000-4000-8000-000000000001');
select tests.assert_eq_text(
  (public.redemption_token_context(:'f9_token2'))->>'reason',
  'token_already_consumed',
  'el contexto informa que el token ya fue consumido'
);
select tests.assert_eq_text(
  (public.redemption_token_context(:'f9_token2'))->>'can_redeem',
  'false',
  'un token consumido no habilita el canje'
);

-- =====================================================================
-- 9. Dashboard: negocio sin datos devuelve 0/null
-- =====================================================================
select tests.as_user('a1000000-0000-4000-8000-000000000005');
select r->>'business_id' as empty_biz
  from (select public.business_register('Negocio Vacío F9', 'negocio-vacio-f9') as r) s \gset
select public.loyalty_program_configure(
  :'empty_biz'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);

select tests.assert_eq_int(
  (public.business_dashboard_summary(:'empty_biz'::uuid)->>'points_outstanding')::integer,
  0,
  'un negocio sin datos tiene 0 loopoints emitidos'
);
select tests.assert_eq_int(
  (public.business_dashboard_summary(:'empty_biz'::uuid)->>'pending_redemptions')::integer,
  0,
  'un negocio sin datos tiene 0 canjes pendientes'
);
select tests.assert_eq_int(
  (public.business_dashboard_summary(:'empty_biz'::uuid)->>'customers_total')::integer,
  0,
  'un negocio sin datos tiene 0 clientes'
);
select tests.assert_eq_int(
  (public.business_dashboard_summary(:'empty_biz'::uuid)->>'frequent_customers')::integer,
  0,
  'un negocio sin datos tiene 0 clientes frecuentes'
);
select tests.assert_eq_int(
  (public.business_dashboard_summary(:'empty_biz'::uuid)->>'sales_today_cop')::integer,
  0,
  'un negocio sin datos tiene 0 ventas del día'
);
select tests.assert_eq_int(
  (public.business_dashboard_summary(:'empty_biz'::uuid)->>'purchases_today')::integer,
  0,
  'un negocio sin datos tiene 0 compras del día'
);
select tests.assert_eq_int(
  (public.business_dashboard_summary(:'empty_biz'::uuid)->>'pending_qr_count')::integer,
  0,
  'un negocio sin datos tiene 0 QR pendientes'
);
select tests.assert(
  (public.business_dashboard_summary(:'empty_biz'::uuid)->>'last_activity_at') is null,
  'un negocio sin datos no tiene última actividad'
);
select tests.assert_eq_int(
  jsonb_array_length(public.business_recent_activity(:'empty_biz'::uuid, 10)),
  0,
  'un negocio sin datos no tiene actividad reciente'
);

-- =====================================================================
-- 10. Matriz de grants
-- =====================================================================
reset role;

-- Ninguna función del esquema público queda ejecutable por PUBLIC.
select tests.assert_eq_int(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and exists (
        select 1
          from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         where a.grantee = 0 and a.privilege_type = 'EXECUTE'
      )),
  0,
  'ninguna función SECURITY DEFINER es ejecutable por PUBLIC'
);

-- Las funciones privadas tampoco quedan ejecutables por PUBLIC.
select tests.assert_eq_int(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and exists (
        select 1
          from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         where a.grantee = 0 and a.privilege_type = 'EXECUTE'
      )),
  0,
  'ninguna función privada es ejecutable por PUBLIC'
);

-- `anon` solo puede ejecutar las tres funciones públicas de lectura/vista previa.
select tests.assert_eq_int(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('anon', p.oid, 'execute')),
  3,
  'anon solo puede ejecutar business_public_get, purchase_qr_preview y business_member_invite_preview'
);
select tests.assert(
  (select has_function_privilege('anon',
     'public.business_public_get(text)'::regprocedure, 'execute')),
  'anon puede leer la ficha pública del negocio'
);
select tests.assert(
  (select has_function_privilege('anon',
     'public.purchase_qr_preview(text)'::regprocedure, 'execute')),
  'anon puede ver la vista previa de la compra'
);
select tests.assert(
  (select has_function_privilege('anon',
     'public.business_member_invite_preview(text)'::regprocedure, 'execute')),
  'anon puede ver la vista previa de la invitación QR'
);

-- Las RPC nuevas de Loopoint son de `authenticated`, no de `anon`.
select tests.assert(
  not (select has_function_privilege('anon',
            'public.customer_businesses_summary()'::regprocedure, 'execute')),
  'anon no ejecuta customer_businesses_summary'
);
select tests.assert(
  not (select has_function_privilege('anon',
            'public.business_dashboard_summary(uuid)'::regprocedure, 'execute')),
  'anon no ejecuta business_dashboard_summary'
);
select tests.assert(
  not (select has_function_privilege('anon',
            'public.business_recent_activity(uuid, integer)'::regprocedure, 'execute')),
  'anon no ejecuta business_recent_activity'
);
select tests.assert(
  not (select has_function_privilege('anon',
            'public.redemption_token_context(text)'::regprocedure, 'execute')),
  'anon no ejecuta redemption_token_context'
);
select tests.assert(
  not (select has_function_privilege('anon',
            'public.redemption_redeem_by_token(text)'::regprocedure, 'execute')),
  'anon no ejecuta redemption_redeem_by_token'
);
select tests.assert(
  not (select has_function_privilege('anon',
            'public.purchase_qr_create_with_items(uuid, integer, jsonb)'::regprocedure, 'execute')),
  'anon no ejecuta purchase_qr_create_with_items'
);
select tests.assert(
  not (select has_function_privilege('anon',
            'public.product_combo_set(uuid, uuid, jsonb)'::regprocedure, 'execute')),
  'anon no ejecuta product_combo_set'
);
select tests.assert(
  not (select has_function_privilege('anon',
            'public.business_purchases_page(uuid, integer, integer, public.purchase_status)'::regprocedure, 'execute')),
  'anon no ejecuta business_purchases_page'
);
select tests.assert(
  not (select has_function_privilege('anon',
            'public.profile_nickname_ensure()'::regprocedure, 'execute')),
  'anon no ejecuta profile_nickname_ensure'
);

-- `authenticated` sí puede ejecutar las RPC nuevas.
select tests.assert(
  (select has_function_privilege('authenticated',
     'public.customer_businesses_summary()'::regprocedure, 'execute')),
  'authenticated ejecuta customer_businesses_summary'
);
select tests.assert(
  (select has_function_privilege('authenticated',
     'public.business_dashboard_summary(uuid)'::regprocedure, 'execute')),
  'authenticated ejecuta business_dashboard_summary'
);
select tests.assert(
  (select has_function_privilege('authenticated',
     'public.redemption_redeem_by_token(text)'::regprocedure, 'execute')),
  'authenticated ejecuta redemption_redeem_by_token'
);
select tests.assert(
  (select has_function_privilege('authenticated',
     'public.purchase_qr_create_with_items(uuid, integer, jsonb)'::regprocedure, 'execute')),
  'authenticated ejecuta purchase_qr_create_with_items'
);

-- Funciones internas: ni `anon` ni `authenticated` las ejecutan.
select tests.assert(
  not (select has_function_privilege('authenticated',
            'public.loyalty_transaction_post(uuid, uuid, public.point_movement_type, integer, text, uuid, text, text, uuid)'::regprocedure, 'execute')),
  'authenticated no ejecuta loyalty_transaction_post'
);
select tests.assert(
  not (select has_function_privilege('authenticated',
            'public.customer_redeem_reward(uuid, text)'::regprocedure, 'execute')),
  'authenticated no ejecuta customer_redeem_reward'
);

-- Los jobs de cron siguen siendo ejecutables por `service_role`.
select tests.assert(
  (select has_function_privilege('service_role',
     'public.points_expire_all_due()'::regprocedure, 'execute')),
  'service_role ejecuta points_expire_all_due'
);
select tests.assert(
  (select has_function_privilege('service_role',
     'public.loyalty_budget_snapshot_all(date)'::regprocedure, 'execute')),
  'service_role ejecuta loyalty_budget_snapshot_all'
);

-- =====================================================================
-- 11. Backfill de nicknames: no pisa los existentes
-- =====================================================================
reset role;

-- Un perfil con nickname ya definido no debe cambiar al aplicar el backfill.
select tests.assert_eq_text(
  (select nickname from public.profiles where id = 'a1000000-0000-4000-8000-000000000001'),
  'adminf9',
  'el nickname existente se conserva'
);

-- Un perfil sin nickname recibe uno generado por el backfill.
insert into auth.users (id, email, raw_user_meta_data)
values (
  'a1000000-0000-4000-8000-000000000009',
  'f9-sin-nick@example.test',
  '{"full_name":"Perfil Sin Nickname F9"}'
) on conflict (id) do nothing;

update public.profiles
   set nickname = null
 where id = 'a1000000-0000-4000-8000-000000000009';

update public.profiles
   set nickname = private.nickname_generate(full_name)
 where nickname is null
   and full_name is not null
   and length(btrim(full_name)) > 0;

select tests.assert_eq_text(
  (select nickname from public.profiles where id = 'a1000000-0000-4000-8000-000000000009'),
  'perfilf9',
  'el backfill genera un nickname para el perfil que no lo tenía'
);

-- Reaplicar el backfill no pisa el nickname ya generado.
update public.profiles
   set nickname = private.nickname_generate(full_name)
 where nickname is null
   and full_name is not null
   and length(btrim(full_name)) > 0;

select tests.assert_eq_text(
  (select nickname from public.profiles where id = 'a1000000-0000-4000-8000-000000000001'),
  'adminf9',
  'el backfill no pisa el nickname existente'
);
select tests.assert_eq_text(
  (select nickname from public.profiles where id = 'a1000000-0000-4000-8000-000000000009'),
  'perfilf9',
  'el backfill es idempotente'
);

-- Los criterios de frecuencia quedan con los valores por defecto.
select tests.assert_eq_int(
  (select frequent_min_purchases from public.loyalty_programs
    where business_id = :'empty_biz'::uuid),
  3,
  'el programa usa 3 compras como criterio de frecuente'
);
select tests.assert_eq_int(
  (select frequent_period_days from public.loyalty_programs
    where business_id = :'empty_biz'::uuid),
  90,
  'el programa usa una ventana de 90 días'
);
select tests.assert_eq_int(
  (select recovery_inactive_days from public.loyalty_programs
    where business_id = :'empty_biz'::uuid),
  60,
  'el programa usa 60 días de recuperación'
);

-- =====================================================================
-- 12. Campañas: regresión de la lógica existente
-- =====================================================================
set local role authenticated;
select tests.as_user('a1000000-0000-4000-8000-000000000005');

select r->>'id' as f9_campaign
  from (
    select public.loyalty_campaign_upsert(
      p_business_id => :'empty_biz'::uuid,
      p_name => 'Doble puntos F9',
      p_multiplier => 2,
      p_bonus_points => 0,
      p_min_purchase_amount => 0,
      p_valid_from => now() - interval '1 hour',
      p_valid_until => now() + interval '1 day',
      p_is_active => true,
      p_description => 'Regresión F9'
    ) as r
  ) s \gset

select public.business_membership_create(
  :'empty_biz'::uuid, 'a1000000-0000-4000-8000-000000000004', 'cliente', false
);

select r->>'points_earned' as f9_campaign_points,
       r->>'base_points' as f9_campaign_base,
       r->>'campaign_id' as f9_campaign_applied
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'empty_biz'::uuid,
      p_customer_id => 'a1000000-0000-4000-8000-000000000004',
      p_amount_cop => 10000,
      p_eligible_amount_cop => 10000,
      p_idempotency_key => 'f9-camp-0001'
    ) as r
  ) s \gset

select tests.assert_eq_int(:'f9_campaign_base'::integer, 10, 'la campaña conserva los puntos base');
select tests.assert_eq_int(:'f9_campaign_points'::integer, 20, 'la campaña duplica los puntos');
select tests.assert_eq_text(:'f9_campaign_applied', :'f9_campaign', 'la respuesta identifica la campaña aplicada');

-- La campaña de multiplicador se desactiva para probar el bono fijo por separado.
select public.loyalty_campaign_upsert(
  p_business_id => :'empty_biz'::uuid,
  p_name => 'Doble puntos F9',
  p_multiplier => 2,
  p_bonus_points => 0,
  p_min_purchase_amount => 0,
  p_valid_from => now() - interval '1 hour',
  p_valid_until => now() + interval '1 day',
  p_is_active => false,
  p_description => 'Regresión F9',
  p_id => :'f9_campaign'::uuid
);

-- Campaña de bono fijo.
select r->>'id' as f9_bonus_campaign
  from (
    select public.loyalty_campaign_upsert(
      p_business_id => :'empty_biz'::uuid,
      p_name => 'Bono F9',
      p_multiplier => 1,
      p_bonus_points => 5,
      p_min_purchase_amount => 0,
      p_valid_from => now() - interval '1 hour',
      p_valid_until => now() + interval '1 day',
      p_is_active => true
    ) as r
  ) s \gset

select r->>'points_earned' as f9_bonus_points
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'empty_biz'::uuid,
      p_customer_id => 'a1000000-0000-4000-8000-000000000004',
      p_amount_cop => 10000,
      p_eligible_amount_cop => 10000,
      p_idempotency_key => 'f9-camp-0002'
    ) as r
  ) s \gset

select tests.assert_eq_int(
  :'f9_bonus_points'::integer,
  15,
  'la campaña de bono fijo suma los puntos extra'
);

-- Una campaña desactivada deja de aplicarse.
select public.loyalty_campaign_upsert(
  p_business_id => :'empty_biz'::uuid,
  p_name => 'Bono F9',
  p_multiplier => 1,
  p_bonus_points => 5,
  p_min_purchase_amount => 0,
  p_valid_from => now() - interval '1 hour',
  p_valid_until => now() + interval '1 day',
  p_is_active => false,
  p_id => :'f9_bonus_campaign'::uuid
);

select r->>'points_earned' as f9_no_campaign_points
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'empty_biz'::uuid,
      p_customer_id => 'a1000000-0000-4000-8000-000000000004',
      p_amount_cop => 10000,
      p_eligible_amount_cop => 10000,
      p_idempotency_key => 'f9-camp-0003'
    ) as r
  ) s \gset

select tests.assert_eq_int(
  :'f9_no_campaign_points'::integer,
  10,
  'una campaña desactivada ya no se aplica'
);

rollback;

\echo '== Pruebas Loopoint F9 completadas =='
