-- =====================================================================
-- Loopoint F7 — Portal del cliente multi-negocio (M4)
--
--  1. Resumen por negocio con saldos distintos (3 negocios)
--  2. Recompensas listas y solicitudes pendientes por negocio
--  3. Frecuencia calculada por negocio (no se mezcla)
--  4. Aislamiento: solo membresías propias y sin datos ajenos
--  5. Canjes globales con slug y logo del negocio
--  6. Permisos: sin sesión y rol anónimo
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('80000000-0000-4000-8000-000000000001', 'f7-admin@example.test', '{"full_name":"Admin F7"}'),
  ('80000000-0000-4000-8000-000000000002', 'f7-cliente@example.test', '{"full_name":"Cliente F7"}'),
  ('80000000-0000-4000-8000-000000000003', 'f7-ajeno@example.test', '{"full_name":"Ajeno F7"}'),
  ('80000000-0000-4000-8000-000000000004', 'f7-cliente2@example.test', '{"full_name":"Cliente Dos F7"}');

set local role authenticated;
select tests.as_user('80000000-0000-4000-8000-000000000001');

-- Tres negocios del mismo administrador.
select r->>'business_id' as biz1
  from (select public.business_register('Café F7', 'cafe-f7') as r) s \gset
select r->>'business_id' as biz2
  from (select public.business_register('Panadería F7', 'panaderia-f7') as r) s \gset
select r->>'business_id' as biz3
  from (select public.business_register('Tienda F7', 'tienda-f7') as r) s \gset

-- El cliente F7 pertenece a los tres; el ajeno solo al segundo.
select public.business_membership_create(
  :'biz1'::uuid, '80000000-0000-4000-8000-000000000002', 'cliente', false
);
select public.business_membership_create(
  :'biz2'::uuid, '80000000-0000-4000-8000-000000000002', 'cliente', false
);
select public.business_membership_create(
  :'biz3'::uuid, '80000000-0000-4000-8000-000000000002', 'cliente', false
);
select public.business_membership_create(
  :'biz2'::uuid, '80000000-0000-4000-8000-000000000003', 'cliente', false
);

-- Programas activos: 1 loopoint por cada 1.000 COP.
select public.loyalty_program_configure(
  :'biz1'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);
select public.loyalty_program_configure(
  :'biz2'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);
select public.loyalty_program_configure(
  :'biz3'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);

-- Recompensas: en biz1 asequible; en biz2 inasequible; en biz3 una inactiva.
select r->>'id' as reward1
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz1'::uuid,
      p_type => 'configurable_benefit',
      p_name => 'Café gratis F7',
      p_points_required => 10,
      p_min_purchase_amount => 0,
      p_max_discount_amount => 5000,
      p_is_active => true
    ) as r
  ) s \gset
select public.loyalty_reward_upsert(
  p_business_id => :'biz2'::uuid,
  p_type => 'configurable_benefit',
  p_name => 'Pan dulce F7',
  p_points_required => 50,
  p_min_purchase_amount => 0,
  p_max_discount_amount => 5000,
  p_is_active => true
);
select public.loyalty_reward_upsert(
  p_business_id => :'biz2'::uuid,
  p_type => 'configurable_benefit',
  p_name => 'Recompensa inactiva F7',
  p_points_required => 1,
  p_min_purchase_amount => 0,
  p_max_discount_amount => 5000,
  p_is_active => false
);

-- Compras: biz1 tres (frecuente activo, 30 loopoints), biz2 una (20), biz3 ninguna.
select public.loyalty_purchase_register(
  :'biz1'::uuid, '80000000-0000-4000-8000-000000000002', 10000, 10000, 'f7-compra-1a'
);
select public.loyalty_purchase_register(
  :'biz1'::uuid, '80000000-0000-4000-8000-000000000002', 10000, 10000, 'f7-compra-1b'
);
select public.loyalty_purchase_register(
  :'biz1'::uuid, '80000000-0000-4000-8000-000000000002', 10000, 10000, 'f7-compra-1c'
);
select public.loyalty_purchase_register(
  :'biz2'::uuid, '80000000-0000-4000-8000-000000000002', 20000, 20000, 'f7-compra-2a'
);

-- Logo público para el listado de canjes.
reset role;
update public.businesses
   set logo_url = 'https://cdn.example.test/business/salon.png'
 where id = :'biz1'::uuid;
set local role authenticated;

-- =====================================================================
-- 1. Resumen de los tres negocios con saldos distintos
-- =====================================================================
select tests.as_user('80000000-0000-4000-8000-000000000002');

select tests.assert_eq_int(
  (select count(*) from public.customer_businesses_summary()),
  3,
  'el cliente ve una fila por cada negocio al que pertenece'
);

select tests.assert_eq_int(
  (select balance from public.customer_businesses_summary()
    where business_id = :'biz1'::uuid),
  30,
  'saldo del primer negocio'
);
select tests.assert_eq_int(
  (select balance from public.customer_businesses_summary()
    where business_id = :'biz2'::uuid),
  20,
  'saldo del segundo negocio'
);
select tests.assert_eq_int(
  (select balance from public.customer_businesses_summary()
    where business_id = :'biz3'::uuid),
  0,
  'saldo del tercer negocio'
);
select tests.assert_eq_text(
  (select string_agg(balance::text, ',' order by balance)
     from public.customer_businesses_summary()),
  '0,20,30',
  'los saldos no se mezclan entre negocios'
);

select tests.assert_eq_int(
  (select ready_rewards from public.customer_businesses_summary()
    where business_id = :'biz1'::uuid),
  1,
  'recompensa lista en el primer negocio'
);
select tests.assert_eq_int(
  (select ready_rewards from public.customer_businesses_summary()
    where business_id = :'biz2'::uuid),
  0,
  'la recompensa inasequible y la inactiva no cuentan'
);
select tests.assert_eq_int(
  (select ready_rewards from public.customer_businesses_summary()
    where business_id = :'biz3'::uuid),
  0,
  'sin saldo no hay recompensas listas'
);

select tests.assert(
  (select is_frequent_active from public.customer_businesses_summary()
    where business_id = :'biz1'::uuid),
  'tres compras en el primer negocio marcan frecuente activo'
);
select tests.assert(
  not (select is_frequent from public.customer_businesses_summary()
        where business_id = :'biz2'::uuid),
  'la frecuencia del segundo negocio no hereda la del primero'
);
select tests.assert(
  (select last_purchase_at is not null from public.customer_businesses_summary()
    where business_id = :'biz1'::uuid),
  'la última compra se informa por negocio'
);
select tests.assert(
  (select loyalty_active from public.customer_businesses_summary()
    where business_id = :'biz1'::uuid),
  'el programa activo se informa en el resumen'
);
select tests.assert_eq_int(
  (select count(*) from public.customer_businesses_summary()
    where role = 'cliente'),
  3,
  'el rol es el del negocio, no el global'
);

-- =====================================================================
-- 2. Solicitud pendiente y recompensa aún lista en biz1
-- =====================================================================
select r->>'redemption_id' as red1
  from (
    select public.reward_request_redemption(
      :'biz1'::uuid, :'reward1'::uuid, 'f7-canje-0001'
    ) as r
  ) s \gset

select tests.assert_eq_int(
  (select pending_redemptions from public.customer_businesses_summary()
    where business_id = :'biz1'::uuid),
  1,
  'la solicitud pendiente cuenta en su negocio'
);
select tests.assert_eq_int(
  (select pending_redemptions from public.customer_businesses_summary()
    where business_id = :'biz2'::uuid),
  0,
  'la solicitud no se atribuye a otro negocio'
);
select tests.assert_eq_int(
  (select balance from public.customer_businesses_summary()
    where business_id = :'biz1'::uuid),
  20,
  'la reserva descuenta del saldo del negocio correcto'
);

-- =====================================================================
-- 3. Aislamiento entre clientes
-- =====================================================================
select tests.as_user('80000000-0000-4000-8000-000000000003');
select tests.assert_eq_int(
  (select count(*) from public.customer_businesses_summary()),
  1,
  'el ajeno solo ve el negocio donde es miembro'
);
select tests.assert_eq_int(
  (select count(*) from public.customer_businesses_summary()
    where business_id = :'biz1'::uuid),
  0,
  'el ajeno no ve el primer negocio'
);
select tests.assert_eq_int(
  (select balance from public.customer_businesses_summary()
    where business_id = :'biz2'::uuid),
  0,
  'el ajeno no hereda el saldo del cliente real'
);

-- =====================================================================
-- 4. Canjes globales con negocio identificable
-- =====================================================================
select tests.as_user('80000000-0000-4000-8000-000000000002');
select tests.assert_eq_int(
  (select count(*) from public.loyalty_my_redemptions(100, 0)),
  1,
  'el cliente ve su canje global'
);
select tests.assert_eq_text(
  (select business_slug from public.loyalty_my_redemptions(100, 0) limit 1),
  'cafe-f7',
  'el canje incluye el slug del negocio'
);
select tests.assert_eq_text(
  (select business_logo_url from public.loyalty_my_redemptions(100, 0) limit 1),
  'https://cdn.example.test/business/salon.png',
  'el canje incluye el logo del negocio'
);

select tests.as_user('80000000-0000-4000-8000-000000000003');
select tests.assert_eq_int(
  (select count(*) from public.loyalty_my_redemptions(100, 0)),
  0,
  'el ajeno no ve canjes de otro cliente'
);

-- =====================================================================
-- 5. Permisos
-- =====================================================================
select set_config('request.jwt.claim.sub', '', true);
select tests.expect_error(
  $$select * from public.customer_businesses_summary()$$,
  'not_authenticated'
);

reset role;
set local role anon;
select tests.expect_error(
  $$select * from public.customer_businesses_summary()$$,
  'permission denied'
);
select tests.expect_error(
  $$select * from public.loyalty_my_redemptions(100, 0)$$,
  'permission denied'
);
reset role;

rollback;

\echo '== Pruebas Loopoint F7 completadas =='
