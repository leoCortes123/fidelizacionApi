-- =====================================================================
-- Loopoint F2 — Identidad, perfil de negocio, logo y cliente frecuente
--
-- Cubre:
--   1. Generación automática de nicknames y resolución de duplicados.
--   2. Formato, reservados, disponibilidad y límite de 2 cambios.
--   3. Aislamiento del perfil personal.
--   4. Perfil de negocio: admin edita; encargado/cliente no; validaciones.
--   5. Logo: URL del bucket y ruta del propio negocio.
--   6. Frecuencia: ventana, compras, gasto, activo y recuperación.
--   7. Listado y detalle de clientes con nickname y frecuencia.
--   8. Grants: anon no ejecuta RPC nuevas.
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('50000000-0000-4000-8000-000000000001', 'f2-admin@example.test', '{"full_name":"Ana Torres"}'),
  ('50000000-0000-4000-8000-000000000002', 'f2-encargado@example.test', '{"full_name":"Encargado F2"}'),
  ('50000000-0000-4000-8000-000000000003', 'f2-cliente@example.test', '{"full_name":"Juan Pérez"}'),
  ('50000000-0000-4000-8000-000000000004', 'f2-cliente2@example.test', '{"full_name":"Juan Perez"}'),
  ('50000000-0000-4000-8000-000000000005', 'f2-sinnombre@example.test', '{}'),
  ('50000000-0000-4000-8000-000000000006', 'f2-ajeno@example.test', '{"full_name":"Otro Admin"}');

-- ---------------------------------------------------------------------
-- 1. Nicknames autogenerados por el trigger
-- ---------------------------------------------------------------------
select tests.assert_eq_text(
  (select nickname from public.profiles where id = '50000000-0000-4000-8000-000000000001'),
  'anatorres',
  'el trigger genera nickname con nombre y apellido'
);
select tests.assert_eq_text(
  (select nickname from public.profiles where id = '50000000-0000-4000-8000-000000000003'),
  'juanperez',
  'se normalizan tildes'
);
select tests.assert_eq_text(
  (select nickname from public.profiles where id = '50000000-0000-4000-8000-000000000004'),
  'juanperez2',
  'un nickname duplicado recibe sufijo'
);
select tests.assert_eq_text(
  (select nickname from public.profiles where id = '50000000-0000-4000-8000-000000000005'),
  'cliente',
  'sin nombre se usa cliente'
);
select tests.assert_eq_int(
  (select nickname_changes from public.profiles where id = '50000000-0000-4000-8000-000000000005'),
  0,
  'el autogenerado no cuenta como cambio'
);

-- ---------------------------------------------------------------------
-- 2. Perfil personal: formato, reservados, duplicados y cambios
-- ---------------------------------------------------------------------
set local role authenticated;
select tests.as_user('50000000-0000-4000-8000-000000000003');

select tests.assert(
  public.profile_nickname_available('nuevoalias'),
  'un alias libre está disponible'
);
select tests.assert(
  not public.profile_nickname_available('anatorres'),
  'un alias de otro usuario no está disponible'
);
select tests.assert(
  not public.profile_nickname_available('ab'),
  'un alias demasiado corto no está disponible'
);
select tests.assert(
  not public.profile_nickname_available('con espacio'),
  'un alias con espacio no está disponible'
);
select tests.assert(
  not public.profile_nickname_available('admin'),
  'un alias reservado no está disponible'
);

select tests.expect_error(
  $$select public.profile_update('Juan Pérez', 'Mayúsculas')$$,
  'invalid_nickname'
);
select tests.expect_error(
  $$select public.profile_update('Juan Pérez', 'admin')$$,
  'nickname_reserved'
);
select tests.expect_error(
  $$select public.profile_update('J', 'juanperez')$$,
  'invalid_full_name'
);
select tests.expect_error(
  $$select public.profile_update('Juan Pérez', 'anatorres')$$,
  'nickname_taken'
);

-- La RLS no permite escribir el nickname directamente.
select tests.expect_error(
  $$update public.profiles set nickname = 'hackeado' where id = auth.uid()$$,
  'permission denied'
);

-- Dos cambios explícitos permitidos; el tercero se rechaza.
select tests.assert_eq_int(
  (public.profile_update('Juan Pérez', 'juanp1')->>'nickname_changes_left')::integer,
  1,
  'primer cambio explícito permitido'
);
select tests.assert_eq_int(
  (public.profile_update('Juan Pérez', 'juanp2')->>'nickname_changes_left')::integer,
  0,
  'segundo cambio explícito permitido'
);
select tests.expect_error(
  $$select public.profile_update('Juan Pérez', 'juanp3')$$,
  'nickname_change_limit'
);
select tests.assert_eq_text(
  (select nickname from public.profiles where id = auth.uid()),
  'juanp2',
  'el nickname rechazado no se guarda'
);

-- Perfil heredado sin alias: el primer valor es gratuito.
reset role;
update public.profiles
   set nickname = null, nickname_changes = 0
 where id = '50000000-0000-4000-8000-000000000005';
set local role authenticated;
select tests.as_user('50000000-0000-4000-8000-000000000005');

select tests.assert_eq_int(
  (public.profile_update('Cliente Sin Nombre', 'cliente-uno')->>'nickname_changes')::integer,
  0,
  'el primer alias elegido en un perfil heredado es gratuito'
);
select tests.assert_eq_text(
  (select nickname from public.profiles where id = auth.uid()),
  'cliente-uno',
  'el alias inicial se guarda'
);

-- Otro perfil heredado: la autogeneración tampoco cuenta como cambio.
reset role;
update public.profiles
   set nickname = null, nickname_changes = 0
 where id = '50000000-0000-4000-8000-000000000005';
set local role authenticated;
select tests.as_user('50000000-0000-4000-8000-000000000005');

select tests.assert_eq_text(
  public.profile_nickname_ensure(),
  'clientenombre',
  'profile_nickname_ensure genera el alias pendiente'
);
select tests.assert_eq_int(
  (select nickname_changes from public.profiles where id = auth.uid()),
  0,
  'la autogeneración posterior no cuenta como cambio'
);

-- get_my_profile expone los campos nuevos.
select tests.assert_eq_int(
  (public.get_my_profile()->>'nickname_changes_left')::integer,
  2,
  'get_my_profile devuelve cambios disponibles'
);
select tests.assert_eq_text(
  public.get_my_profile()->>'nickname',
  'clientenombre',
  'get_my_profile devuelve el nickname'
);

-- ---------------------------------------------------------------------
-- 3. Negocio: perfil completo, validaciones y aislamiento
-- ---------------------------------------------------------------------
select tests.as_user('50000000-0000-4000-8000-000000000001');

select r->>'business_id' as biz
  from (select public.business_register('Café Loopoint', 'cafe-loopoint-f2') as r) s \gset

select tests.assert(:'biz' <> '', 'business_register devuelve el negocio');

select public.business_membership_create(
  :'biz'::uuid, '50000000-0000-4000-8000-000000000002', 'encargado', false
);
select public.business_membership_create(
  :'biz'::uuid, '50000000-0000-4000-8000-000000000003', 'cliente', false
);

select r->>'phone_whatsapp' as whatsapp, r->>'website' as website,
       r->>'instagram' as instagram, r->>'name' as business_name
  from (
    select public.business_profile_update(
      p_business_id => :'biz'::uuid,
      p_name => 'Café Loopoint Centro',
      p_description => 'Café de especialidad y repostería.',
      p_address => 'Calle 10 # 5-20',
      p_neighborhood => 'Centro',
      p_city => 'Bogotá',
      p_phone_whatsapp => '+57 300 123 4567',
      p_phone => '(601) 555-0000',
      p_instagram => '@cafeloopoint',
      p_website => 'cafeloopoint.co'
    ) as r
  ) s \gset

select tests.assert_eq_text(:'whatsapp', '+573001234567', 'normaliza el WhatsApp');
select tests.assert_eq_text(:'website', 'https://cafeloopoint.co', 'añade https a la web');
select tests.assert_eq_text(:'instagram', 'cafeloopoint', 'quita la arroba de Instagram');
select tests.assert_eq_text(:'business_name', 'Café Loopoint Centro', 'actualiza el nombre');

select tests.expect_error(
  format(
    $$select public.business_profile_update(%L::uuid, 'Café Loopoint', null, null, null, null, 'abc')$$,
    :'biz'
  ),
  'invalid_whatsapp'
);
select tests.expect_error(
  format(
    $$select public.business_profile_update(%L::uuid, 'Café Loopoint', null, null, null, null, null, null, null, 'no es una url')$$,
    :'biz'
  ),
  'invalid_website'
);
select tests.expect_error(
  format($$select public.business_profile_update(%L::uuid, 'X')$$, :'biz'),
  'invalid_business_name'
);

select tests.as_user('50000000-0000-4000-8000-000000000002');
select tests.expect_error(
  format(
    $$select public.business_profile_update(%L::uuid, 'Nombre del encargado')$$,
    :'biz'
  ),
  'forbidden'
);
select tests.assert_eq_text(
  public.business_profile_get(:'biz'::uuid)->>'city',
  'Bogotá',
  'el encargado puede leer el perfil del negocio'
);

select tests.as_user('50000000-0000-4000-8000-000000000003');
select tests.assert_eq_text(
  public.business_profile_get(:'biz'::uuid)->>'description',
  'Café de especialidad y repostería.',
  'el cliente puede leer el perfil del negocio'
);
select tests.expect_error(
  format(
    $$select public.business_profile_update(%L::uuid, 'Nombre del cliente')$$,
    :'biz'
  ),
  'forbidden'
);

-- ---------------------------------------------------------------------
-- 4. Logo: solo el admin, solo la ruta del propio negocio
-- ---------------------------------------------------------------------
select tests.as_user('50000000-0000-4000-8000-000000000001');

select r->>'logo_url' as logo
  from (
    select public.business_logo_set(
      :'biz'::uuid,
      'https://demo.supabase.co/storage/v1/object/public/business-assets/business/'
        || :'biz' || '/logo.png'
    ) as r
  ) s \gset

select tests.assert(:'logo' like '%/business/' || :'biz' || '/logo.png', 'guarda el logo del negocio');

select tests.expect_error(
  format(
    $$select public.business_logo_set(%L::uuid, %L)$$,
    :'biz',
    'https://demo.supabase.co/storage/v1/object/public/business-assets/business/00000000-0000-4000-8000-000000000099/logo.png'
  ),
  'logo_outside_business'
);
select tests.expect_error(
  format(
    $$select public.business_logo_set(%L::uuid, %L)$$,
    :'biz',
    'https://demo.supabase.co/storage/v1/object/public/otro-bucket/business/' || :'biz' || '/logo.png'
  ),
  'invalid_logo_url'
);

select tests.as_user('50000000-0000-4000-8000-000000000002');
select tests.expect_error(
  format(
    $$select public.business_logo_set(%L::uuid, %L)$$,
    :'biz',
    'https://demo.supabase.co/storage/v1/object/public/business-assets/business/' || :'biz' || '/otro.png'
  ),
  'forbidden'
);

select tests.as_user('50000000-0000-4000-8000-000000000001');
select public.business_logo_set(:'biz'::uuid, null);
select tests.assert(
  (select logo_url is null from public.businesses where id = :'biz'::uuid),
  'el admin puede quitar el logo'
);

-- La ficha pública no requiere sesión y solo muestra datos públicos.
set local role anon;
select tests.assert_eq_text(
  (select description from public.business_public_get('cafe-loopoint-f2')),
  'Café de especialidad y repostería.',
  'business_public_get expone la descripción pública'
);
select tests.assert_eq_text(
  (select city from public.business_public_get('cafe-loopoint-f2')),
  'Bogotá',
  'business_public_get expone la ciudad'
);

-- ---------------------------------------------------------------------
-- 5. Cliente frecuente
-- ---------------------------------------------------------------------
set local role authenticated;
select tests.as_user('50000000-0000-4000-8000-000000000001');

select public.loyalty_program_configure(
  :'biz'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);

select tests.as_user('50000000-0000-4000-8000-000000000003');
select public.business_join('cafe-loopoint-f2');

select tests.as_user('50000000-0000-4000-8000-000000000001');
select public.loyalty_purchase_register(
  :'biz'::uuid, '50000000-0000-4000-8000-000000000003', 10000, 10000, 'f2-compra-0001'
);
select public.loyalty_purchase_register(
  :'biz'::uuid, '50000000-0000-4000-8000-000000000003', 10000, 10000, 'f2-compra-0002'
);

select tests.assert(
  not (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_frequent')::boolean,
  'dos compras no alcanzan para ser frecuente'
);

select public.loyalty_purchase_register(
  :'biz'::uuid, '50000000-0000-4000-8000-000000000003', 10000, 10000, 'f2-compra-0003'
);

select tests.assert(
  (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_frequent')::boolean,
  'tres compras en la ventana hacen frecuente al cliente'
);
select tests.assert(
  (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_frequent_active')::boolean,
  'con compra reciente el frecuente está activo'
);

-- Ventana de 40 días: sigue siendo frecuente, pero deja de estar activo.
reset role;
update public.loyalty_purchase_events
   set created_at = now() - interval '40 days'
 where business_id = :'biz'::uuid;
set local role authenticated;

select tests.assert(
  (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_frequent')::boolean,
  'las compras dentro de 90 días siguen contando'
);
select tests.assert(
  not (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_frequent_active')::boolean,
  'sin compras en 30 días deja de estar activo'
);
select tests.assert(
  not (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_recovering')::boolean,
  'a los 40 días aún no está en recuperación'
);

-- 70 días: frecuente dentro de la ventana y en recuperación.
reset role;
update public.loyalty_purchase_events
   set created_at = now() - interval '70 days'
 where business_id = :'biz'::uuid;
set local role authenticated;

select tests.assert(
  (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_recovering')::boolean,
  'sin compras en 60 días queda en recuperación'
);

-- 100 días: fuera de la ventana de 90, ya no es frecuente.
reset role;
update public.loyalty_purchase_events
   set created_at = now() - interval '100 days'
 where business_id = :'biz'::uuid;
set local role authenticated;

select tests.assert(
  not (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_frequent')::boolean,
  'las compras fuera de la ventana no cuentan'
);

-- Gasto mínimo configurable.
select public.loyalty_program_frequent_update(
  :'biz'::uuid, 3, 90, 50000, 30, 60
);

reset role;
update public.loyalty_purchase_events
   set created_at = now() - interval '5 days'
 where business_id = :'biz'::uuid;
set local role authenticated;

select tests.assert(
  not (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_frequent')::boolean,
  'el gasto mínimo se aplica'
);

reset role;
update public.loyalty_purchase_events
   set amount_cop = 30000
 where business_id = :'biz'::uuid
   and id = (
     select id from public.loyalty_purchase_events
      where business_id = :'biz'::uuid
      order by created_at limit 1
   );
set local role authenticated;

select tests.assert(
  (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_frequent')::boolean,
  'sumando gasto suficiente vuelve a ser frecuente'
);

-- Criterios configurables por el admin.
select tests.assert_eq_int(
  (public.loyalty_program_frequent_update(
    :'biz'::uuid, 2, 3650, 0, 180, 200
  )->>'frequent_min_purchases')::integer,
  2,
  'el admin cambia los criterios de frecuencia'
);

select tests.expect_error(
  format($$select public.loyalty_program_frequent_update(%L::uuid, 0, 90, 0, 30, 60)$$, :'biz'),
  'invalid_frequent_min_purchases'
);
select tests.expect_error(
  format($$select public.loyalty_program_frequent_update(%L::uuid, 3, 3, 0, 30, 60)$$, :'biz'),
  'invalid_frequent_period_days'
);
select tests.expect_error(
  format($$select public.loyalty_program_frequent_update(%L::uuid, 3, 90, 0, 90, 60)$$, :'biz'),
  'invalid_recovery_inactive_days'
);

select tests.as_user('50000000-0000-4000-8000-000000000002');
select tests.expect_error(
  format($$select public.loyalty_program_frequent_update(%L::uuid, 3, 90, 0, 30, 60)$$, :'biz'),
  'forbidden'
);

-- El cliente puede consultar su propia frecuencia, no la de otro.
select tests.as_user('50000000-0000-4000-8000-000000000003');
select tests.assert(
  (public.business_customer_frequency(
    :'biz'::uuid, '50000000-0000-4000-8000-000000000003'
  )->>'is_frequent')::boolean,
  'el cliente consulta su propia frecuencia'
);
select tests.expect_error(
  format(
    $$select public.business_customer_frequency(%L::uuid, '50000000-0000-4000-8000-000000000004')$$,
    :'biz'
  ),
  'forbidden'
);

-- Un usuario ajeno no puede consultar la frecuencia del negocio.
select tests.as_user('50000000-0000-4000-8000-000000000006');
select tests.expect_error(
  format(
    $$select public.business_customer_frequency(%L::uuid, '50000000-0000-4000-8000-000000000003')$$,
    :'biz'
  ),
  'business_not_found_or_no_access'
);

-- ---------------------------------------------------------------------
-- 6. Listado y detalle de clientes con frecuencia
-- ---------------------------------------------------------------------
select tests.as_user('50000000-0000-4000-8000-000000000001');

select tests.assert_eq_int(
  (select count(*) from public.staff_list_customers(
    p_business_id => :'biz'::uuid
  )),
  1,
  'el listado por negocio solo muestra sus clientes'
);
select tests.assert_eq_text(
  (select nickname from public.staff_list_customers(p_business_id => :'biz'::uuid)),
  'juanp2',
  'el listado incluye el nickname'
);
select tests.assert(
  (select is_frequent from public.staff_list_customers(p_business_id => :'biz'::uuid)),
  'el listado incluye el badge de frecuente'
);
select tests.assert_eq_int(
  (select count(*) from public.staff_list_customers(
    p_search => 'juanp2',
    p_business_id => :'biz'::uuid
  )),
  1,
  'la búsqueda encuentra por nickname'
);
select tests.assert_eq_int(
  (select count(*) from public.staff_list_customers(
    p_search => 'zzzz',
    p_business_id => :'biz'::uuid
  )),
  0,
  'la búsqueda filtra sin resultados'
);

select tests.assert_eq_text(
  (public.staff_get_customer(
    '50000000-0000-4000-8000-000000000003', :'biz'::uuid
  )->'profile'->>'nickname'),
  'juanp2',
  'el detalle incluye el nickname'
);
select tests.assert(
  (public.staff_get_customer(
    '50000000-0000-4000-8000-000000000003', :'biz'::uuid
  )->>'is_frequent')::boolean,
  'el detalle incluye la frecuencia'
);
select tests.assert_eq_int(
  (public.staff_get_customer(
    '50000000-0000-4000-8000-000000000003', :'biz'::uuid
  )->>'purchase_count')::integer,
  3,
  'el detalle cuenta las compras del negocio'
);

-- Un encargado del negocio puede consultar; un admin de otro negocio no.
select tests.as_user('50000000-0000-4000-8000-000000000002');
select tests.assert(
  public.staff_get_customer(
    '50000000-0000-4000-8000-000000000003', :'biz'::uuid
  ) is not null,
  'el encargado consulta el detalle del cliente'
);

select tests.as_user('50000000-0000-4000-8000-000000000006');
select tests.expect_error(
  format(
    $$select public.staff_get_customer('50000000-0000-4000-8000-000000000003', %L::uuid)$$,
    :'biz'
  ),
  'business_not_found_or_no_access'
);

select tests.as_user('50000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.staff_list_customers(p_business_id => %L::uuid)$$, :'biz'),
  'forbidden'
);

-- ---------------------------------------------------------------------
-- 7. Grants: anon no ejecuta las RPC nuevas
-- ---------------------------------------------------------------------
reset role;
select tests.assert(
  not has_function_privilege('anon', 'public.profile_nickname_ensure()', 'execute'),
  'anon no ejecuta profile_nickname_ensure'
);
select tests.assert(
  not has_function_privilege(
    'anon',
    'public.business_logo_set(uuid, text)',
    'execute'
  ),
  'anon no ejecuta business_logo_set'
);
select tests.assert(
  not has_function_privilege(
    'anon',
    'public.business_profile_update(uuid, text, text, text, text, text, text, text, text, text)',
    'execute'
  ),
  'anon no ejecuta business_profile_update'
);
select tests.assert(
  has_function_privilege(
    'authenticated',
    'public.profile_update(text, text)',
    'execute'
  ),
  'authenticated ejecuta profile_update'
);

\echo '== Pruebas Loopoint F2 completadas =='
