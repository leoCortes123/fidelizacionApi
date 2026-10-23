\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off
\echo '== Pruebas de integración PostgreSQL =='

begin;

-- Usuarios de prueba (sin datos personales reales).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-000000000001', 'admin@example.test', '{"full_name":"Admin Prueba"}'),
  ('00000000-0000-4000-8000-000000000002', 'admin2@example.test', '{"full_name":"Admin Dos"}'),
  ('00000000-0000-4000-8000-000000000003', 'cliente1@example.test', '{"full_name":"Cliente Uno"}'),
  ('00000000-0000-4000-8000-000000000004', 'cliente2@example.test', '{"full_name":"Cliente Dos"}');

insert into public.user_roles (user_id, role) values
  ('00000000-0000-4000-8000-000000000001', 'admin'),
  ('00000000-0000-4000-8000-000000000002', 'admin');

select tests.assert_eq_int((select count(*) from public.profiles), 4, 'trigger crea 4 perfiles');
select tests.assert_eq_int((select count(*) from public.user_roles where role = 'customer'), 4, 'trigger asigna rol customer');
select tests.assert_eq_int((select count(*) from public.user_roles where role = 'admin'), 2, 'administradores autorizados existen');
select tests.assert_eq_int((select count(*) from public.user_roles where role = 'registrar'), 0, 'el rol registrar no se usa');

set local role authenticated;
select tests.as_user('00000000-0000-4000-8000-000000000001');

-- ---------------------------------------------------------------------
-- Configuración y autorización administrativa
-- ---------------------------------------------------------------------
select public.admin_update_settings('{"min_purchase_amount":1000}'::jsonb);
select tests.assert_eq_int(
  (select min_purchase_amount from public.program_settings where id),
  1000,
  'admin actualiza compra mínima'
);

select tests.expect_error(
  $$select public.admin_update_settings('{"min_purchase_amount":0}'::jsonb)$$,
  'forbidden'
);
select tests.expect_sqlstate(
  $$select public.admin_update_settings('{"cop_per_point_unit":0}'::jsonb)$$,
  '23514'
);

select tests.as_user('00000000-0000-4000-8000-000000000003');
select tests.expect_error(
  $$select public.admin_get_settings()$$,
  'forbidden'
);
select tests.expect_error(
  $$select public.admin_get_config_history(10)$$,
  'forbidden'
);

-- ---------------------------------------------------------------------
-- Generación de compras
-- ---------------------------------------------------------------------
select tests.as_user('00000000-0000-4000-8000-000000000003');
select tests.expect_error(
  $$select public.create_purchase(15500)$$,
  'forbidden'
);

select tests.as_user('00000000-0000-4000-8000-000000000002');
select r->>'token' as p1_token, r->>'purchase_id' as p1_id
  from (select public.create_purchase(15500) as r) s \gset
select r->>'token' as p2_token, r->>'purchase_id' as p2_id
  from (select public.create_purchase(3000) as r) s \gset
select r->>'token' as p3_token, r->>'purchase_id' as p3_id
  from (select public.create_purchase(5000) as r) s \gset
select r->>'token' as p4_token, r->>'purchase_id' as p4_id
  from (select public.create_purchase(7000) as r) s \gset
select r->>'token' as p6_token, r->>'purchase_id' as p6_id
  from (select public.create_purchase(15500) as r) s \gset

select tests.assert(length(:'p1_token') >= 40, 'token tiene longitud criptográfica');
select tests.assert(:'p1_token' <> :'p2_token', 'tokens únicos por compra');
select tests.assert_eq_int(
  (select count(*) from public.purchases where id = :'p1_id'::uuid),
  1,
  'compra válida registrada'
);
select tests.assert_eq_int(
  (select points_awarded from public.purchases where id = :'p1_id'::uuid),
  0,
  'puntos no se acreditan al generar'
);
select tests.assert(
  (select token_hash <> :'p1_token' and length(token_hash) = 64
     from public.purchases where id = :'p1_id'::uuid),
  'solo se guarda el hash SHA-256 del token'
);
select tests.assert_eq_int(
  (select count(distinct token_hash) from public.purchases),
  5,
  'hashes de tokens distintos'
);
select tests.assert_eq_int(
  (select points_awarded from public.purchases where id = :'p1_id'::uuid),
  0,
  'puntos pendientes al crear'
);

select tests.expect_error($$select public.create_purchase(0)$$, 'amount_invalid');
select tests.expect_error($$select public.create_purchase(-1000)$$, 'amount_invalid');
select tests.expect_error($$select public.create_purchase(500)$$, 'amount_below_minimum');
select tests.expect_error($$select public.create_purchase(50000001)$$, 'amount_too_large');

-- ---------------------------------------------------------------------
-- Reclamación y cálculo de puntos
-- ---------------------------------------------------------------------
select tests.as_user('00000000-0000-4000-8000-000000000003');
select r->>'points_awarded' as claim1_points, r->>'balance' as claim1_balance
  from (select public.claim_purchase(:'p1_token') as r) s \gset
select tests.assert_eq_int(:'claim1_points'::bigint, 15, 'cálculo: 15.500 COP = 15 puntos');
select tests.assert_eq_int(:'claim1_balance'::bigint, 15, 'saldo acreditado tras reclamar');
select tests.assert_eq_int(
  (select count(*) from public.points_ledger where purchase_id = :'p1_id'::uuid),
  1,
  'un único movimiento de crédito por compra'
);

select tests.expect_error(
  format('select public.claim_purchase(%L)', :'p1_token'),
  'purchase_already_claimed'
);

select tests.as_user('00000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format('select public.claim_purchase(%L)', :'p1_token'),
  'purchase_already_claimed'
);
select public.claim_purchase(:'p2_token');
select tests.assert_eq_int((select count(*) from public.purchases), 1, 'cliente 2 solo ve sus compras');
select tests.assert_eq_int((select count(*) from public.points_ledger), 1, 'cliente 2 solo ve sus movimientos');
select tests.assert_eq_int(
  (select count(*) from public.purchases where claimed_by = '00000000-0000-4000-8000-000000000003'),
  0,
  'cliente 2 no ve compras del cliente 1'
);

select tests.as_user('00000000-0000-4000-8000-000000000003');
select tests.assert_eq_int((select count(*) from public.purchases), 1, 'cliente 1 solo ve sus compras');
select tests.assert_eq_int((select count(*) from public.points_ledger), 1, 'cliente 1 solo ve sus movimientos');
select tests.assert_eq_int(
  (select count(*) from public.purchases where claimed_by = '00000000-0000-4000-8000-000000000004'),
  0,
  'cliente 1 no ve compras del cliente 2'
);

-- QR expirado
reset role;
update public.purchases
   set created_at = now() - interval '2 hours',
       expires_at = now() - interval '1 hour'
 where id = :'p3_id'::uuid;
set local role authenticated;
select tests.as_user('00000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format('select public.claim_purchase(%L)', :'p3_token'),
  'purchase_expired'
);
select tests.as_user('00000000-0000-4000-8000-000000000002');
select count(*) from public.staff_list_purchases(100, 0, null);
select tests.assert_eq_text(
  (select status::text from public.purchases where id = :'p3_id'::uuid),
  'expired',
  'barrido marca compras expiradas'
);

-- Compra cancelada
select public.staff_cancel_purchase(:'p4_id'::uuid, 'Prueba de cancelación');
select tests.assert_eq_text(
  (select status::text from public.purchases where id = :'p4_id'::uuid),
  'cancelled',
  'compra cancelada por registrador'
);
select tests.as_user('00000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format('select public.claim_purchase(%L)', :'p4_token'),
  'purchase_cancelled'
);
select tests.expect_error(
  format('select public.staff_cancel_purchase(%L::uuid, %L)', :'p4_id', 'otra'),
  'forbidden'
);

-- Snapshot de reglas: cambiar el máximo no afecta compras ya creadas
select tests.as_user('00000000-0000-4000-8000-000000000001');
select public.admin_update_settings('{"max_points_per_purchase":5}'::jsonb);
select tests.as_user('00000000-0000-4000-8000-000000000002');
select r->>'token' as p5_token, r->>'purchase_id' as p5_id
  from (select public.create_purchase(15500) as r) s \gset
select tests.assert_eq_int(
  (select (settings_snapshot->>'max_points_per_purchase')::int from public.purchases where id = :'p5_id'::uuid),
  5,
  'compra nueva toma la configuración vigente'
);
select tests.as_user('00000000-0000-4000-8000-000000000004');
select r->>'points_awarded' as p6_points
  from (select public.claim_purchase(:'p6_token') as r) s \gset
select tests.assert_eq_int(:'p6_points'::bigint, 15, 'compra anterior conserva reglas antiguas');
select tests.as_user('00000000-0000-4000-8000-000000000003');
select r->>'points_awarded' as p5_points
  from (select public.claim_purchase(:'p5_token') as r) s \gset
select tests.assert_eq_int(:'p5_points'::bigint, 5, 'límite máximo de puntos se aplica');

select tests.as_user('00000000-0000-4000-8000-000000000001');
select public.admin_update_settings('{"max_points_per_purchase":500}'::jsonb);

-- ---------------------------------------------------------------------
-- Canjes aplicados por el administrador
-- ---------------------------------------------------------------------
-- Un cliente no puede aplicar canjes desde la API.
select tests.as_user('00000000-0000-4000-8000-000000000003');
select tests.expect_error(
  $$select public.admin_redeem_reward(
      '00000000-0000-4000-8000-000000000003'::uuid,
      '11111111-1111-4111-8111-111111111111'::uuid,
      'idem-cliente1-0001', 'sin saldo')$$,
  'forbidden'
);

-- El administrador tampoco puede canjear si el cliente no tiene saldo.
select tests.as_user('00000000-0000-4000-8000-000000000001');
select tests.expect_error(
  $$select public.admin_redeem_reward(
      '00000000-0000-4000-8000-000000000003'::uuid,
      '11111111-1111-4111-8111-111111111111'::uuid,
      'idem-cliente1-0002', 'sin saldo')$$,
  'insufficient_points'
);
select tests.assert_eq_int(
  (select count(*) from public.redemptions where customer_id = '00000000-0000-4000-8000-000000000003'),
  0,
  'canje fallido no deja registros'
);

-- Cliente 2 reúne puntos suficientes
select tests.as_user('00000000-0000-4000-8000-000000000002');
select r->>'token' as p7_token
  from (select public.create_purchase(30000) as r) s \gset
select tests.as_user('00000000-0000-4000-8000-000000000004');
select public.claim_purchase(:'p7_token');
select tests.as_user('00000000-0000-4000-8000-000000000002');
select r->>'code' as redeem1_code,
       r->>'redemption_id' as redeem1_id,
       r->>'balance' as redeem1_balance
  from (select public.admin_redeem_reward(
          '00000000-0000-4000-8000-000000000004'::uuid,
          '11111111-1111-4111-8111-111111111111'::uuid,
          'idem-cliente2-0001', 'Canje en caja') as r) s \gset
select tests.assert(:'redeem1_code' like 'TP%', 'canje genera código único');
select tests.assert_eq_int(:'redeem1_balance'::bigint, 8, 'canje descuenta 40 puntos');
select tests.assert_eq_text(
  (select status::text from public.redemptions where id = :'redeem1_id'::uuid),
  'redeemed',
  'el canje del panel queda entregado'
);
select tests.assert(
  (select delivered_by = '00000000-0000-4000-8000-000000000002'
     from public.redemptions where id = :'redeem1_id'::uuid),
  'el canje registra al administrador'
);
select tests.assert_eq_int(
  (select count(*) from public.points_ledger
    where redemption_id = :'redeem1_id'::uuid and movement_type = 'redemption_debit'),
  1,
  'un único débito por canje'
);

select r->>'code' as redeem1_dup_code, r->>'duplicate' as redeem1_dup
  from (select public.admin_redeem_reward(
          '00000000-0000-4000-8000-000000000004'::uuid,
          '11111111-1111-4111-8111-111111111111'::uuid,
          'idem-cliente2-0001', 'Reintento') as r) s \gset
select tests.assert_eq_text(:'redeem1_dup', 'true', 'idempotencia detecta reintento');
select tests.assert_eq_text(:'redeem1_dup_code', :'redeem1_code', 'reintento devuelve el mismo código');
select tests.assert_eq_int(
  (select count(*) from public.redemptions where customer_id = '00000000-0000-4000-8000-000000000004'),
  1,
  'reintento no duplica canjes'
);

-- Segundo canje con cancelación y devolución
select tests.as_user('00000000-0000-4000-8000-000000000002');
select r->>'token' as p8_token from (select public.create_purchase(50000) as r) s \gset
select tests.as_user('00000000-0000-4000-8000-000000000004');
select public.claim_purchase(:'p8_token');
select tests.as_user('00000000-0000-4000-8000-000000000002');
select r->>'redemption_id' as redeem2_id, r->>'code' as redeem2_code
  from (select public.admin_redeem_reward(
          '00000000-0000-4000-8000-000000000004'::uuid,
          '55555555-5555-4555-8555-555555555555'::uuid,
          'idem-cliente2-0002', 'Segundo canje') as r) s \gset
select tests.assert_eq_int(
  (select coalesce(sum(points),0) from public.points_ledger where customer_id = '00000000-0000-4000-8000-000000000004'),
  38,
  'segundo canje descuenta 20 puntos'
);
select public.admin_cancel_redemption(:'redeem2_id'::uuid, 'Se aplicó por error');
select tests.assert_eq_int(
  (select coalesce(sum(points),0) from public.points_ledger where customer_id = '00000000-0000-4000-8000-000000000004'),
  58,
  'cancelación devuelve los puntos'
);
select tests.assert_eq_text(
  (select status::text from public.redemptions where id = :'redeem2_id'::uuid),
  'cancelled',
  'cancelación marca el canje'
);
select tests.expect_error(
  format('select public.admin_cancel_redemption(%L::uuid, %L)', :'redeem2_id', 'otra vez'),
  'redemption_cancelled'
);

-- La RPC heredada del cliente queda deshabilitada por completo.
select tests.as_user('00000000-0000-4000-8000-000000000004');
select tests.expect_error(
  $$select public.customer_redeem_reward(
      '11111111-1111-4111-8111-111111111111'::uuid, 'idem-cliente2-0003')$$,
  'permission denied'
);

-- ---------------------------------------------------------------------
-- RLS y privilegios directos
-- ---------------------------------------------------------------------
select tests.as_user('00000000-0000-4000-8000-000000000003');
select tests.assert_eq_int((select count(*) from public.profiles), 1, 'RLS: perfil propio únicamente');
select tests.assert_eq_int(
  (select count(*) from public.profiles where id = '00000000-0000-4000-8000-000000000004'),
  0,
  'RLS: no se ve el perfil de otro cliente'
);
select tests.assert_eq_int((select count(*) from public.user_roles), 1, 'RLS: roles propios únicamente');
select tests.assert_eq_int((select count(*) from public.audit_log), 0, 'RLS: cliente no lee auditoría');
select tests.assert_eq_int((select count(*) from public.purchases), 2, 'RLS: compras propias');
select tests.assert_eq_int((select count(*) from public.points_ledger), 2, 'RLS: movimientos propios');

select tests.expect_sqlstate(
  $$insert into public.purchases (amount_cop, registrar_id, token_hash, expires_at)
    values (1000, '00000000-0000-4000-8000-000000000003', repeat('a',64), now() + interval '1 hour')$$,
  '42501'
);
select tests.expect_sqlstate(
  $$insert into public.points_ledger (customer_id, movement_type, points, idempotency_key)
    values ('00000000-0000-4000-8000-000000000003', 'admin_adjustment', 100, 'hack-1')$$,
  '42501'
);
select tests.expect_sqlstate(
  $$update public.points_ledger set points = 9999$$,
  '42501'
);
select tests.expect_sqlstate(
  $$delete from public.points_ledger$$,
  '42501'
);
select tests.expect_sqlstate(
  $$update public.user_roles set role = 'admin'$$,
  '42501'
);
select tests.expect_sqlstate(
  $$update public.profiles set email = 'otro@example.test'$$,
  '42501'
);
update public.profiles set full_name = 'Cliente Uno Editado'
 where id = '00000000-0000-4000-8000-000000000003';
select tests.assert_eq_text(
  (select full_name from public.profiles where id = '00000000-0000-4000-8000-000000000003'),
  'Cliente Uno Editado',
  'cliente puede editar su nombre visible'
);

select tests.as_user('00000000-0000-4000-8000-000000000001');
select tests.assert((select count(*) from public.audit_log) > 0, 'admin lee auditoría');
select tests.assert(
  (select count(*) from public.audit_log
    where metadata::text like '%' || :'p1_token' || '%') = 0,
  'la auditoría no contiene tokens completos'
);
select tests.assert((select count(*) from public.config_history) >= 3, 'historial de configuración registrado');
select tests.expect_error(
  format('select public.admin_revoke_role(%L::uuid, %L::public.app_role)', '00000000-0000-4000-8000-000000000001', 'admin'),
  'cannot_revoke_own_admin'
);

-- Roles administrados por el servidor
select tests.as_user('00000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format('select public.admin_grant_role(%L::uuid, %L::public.app_role)', '00000000-0000-4000-8000-000000000003', 'admin'),
  'forbidden'
);
select tests.as_user('00000000-0000-4000-8000-000000000001');
select public.admin_grant_role('00000000-0000-4000-8000-000000000004', 'admin');
select tests.assert_eq_int(
  (select count(*) from public.user_roles where user_id = '00000000-0000-4000-8000-000000000004' and role = 'admin'),
  1,
  'admin habilita a otro administrador'
);
select tests.as_user('00000000-0000-4000-8000-000000000004');
select tests.assert(
  (public.create_purchase(2000)->>'purchase_id') is not null,
  'administrador habilitado puede crear compras'
);
select tests.as_user('00000000-0000-4000-8000-000000000001');
select public.admin_revoke_role('00000000-0000-4000-8000-000000000004', 'admin');
select tests.as_user('00000000-0000-4000-8000-000000000004');
select tests.expect_error($$select public.create_purchase(2000)$$, 'forbidden');

-- Listado y detalle de clientes para el personal
select tests.as_user('00000000-0000-4000-8000-000000000002');
select tests.assert_eq_int(
  (select count(*) from public.staff_list_customers('', 50, 0, 'created_at', 'desc')),
  2,
  'personal lista clientes sin administradores'
);
select tests.assert_eq_int(
  (select count(*) from public.staff_list_customers('Cliente Dos', 50, 0, 'name', 'asc')),
  1,
  'búsqueda por nombre'
);
select tests.assert_eq_text(
  (select public.staff_get_customer('00000000-0000-4000-8000-000000000004')->'profile'->>'email'),
  'cliente2@example.test',
  'detalle de cliente para personal'
);

-- Inmutabilidad del libro incluso para el propietario de la base
reset role;
select tests.expect_error(
  $$update public.points_ledger set points = 1$$,
  'points_ledger_is_immutable'
);
select tests.expect_error(
  $$delete from public.points_ledger$$,
  'points_ledger_is_immutable'
);

-- Saldo negativo bloqueado por restricción diferida
savepoint neg_test;
  set constraints points_ledger_nonnegative immediate;
  select tests.expect_error(
    format($$insert into public.points_ledger (customer_id, movement_type, points, idempotency_key)
             values (%L, 'admin_adjustment', -1000000, 'neg-test')$$,
           '00000000-0000-4000-8000-000000000003'),
    'negative_points_balance'
  );
rollback to savepoint neg_test;

-- ---------------------------------------------------------------------
-- Vencimiento de puntos configurable
-- ---------------------------------------------------------------------
set local role authenticated;
select tests.as_user('00000000-0000-4000-8000-000000000001');
select tests.expect_error($$select public.admin_expire_points()$$, 'expiry_disabled');
select public.admin_update_settings('{"points_expiry_days":1}'::jsonb);

reset role;
-- Crédito sintético antiguo (el libro es inmutable; se inserta ya fechado).
insert into public.purchases (amount_cop, registrar_id, token_hash, expires_at, created_at)
values (
  15000,
  '00000000-0000-4000-8000-000000000002',
  encode(extensions.digest('old-expiry-test-token', 'sha256'), 'hex'),
  now() + interval '1 day',
  now() - interval '2 days'
)
returning id as old_purchase_id \gset

insert into public.points_ledger (
  customer_id, movement_type, points, purchase_id, idempotency_key, created_at
) values (
  '00000000-0000-4000-8000-000000000003',
  'purchase_credit',
  15,
  :'old_purchase_id'::uuid,
  'old-credit-expiry-test',
  now() - interval '2 days'
);
set local role authenticated;

select tests.as_user('00000000-0000-4000-8000-000000000001');
select r->>'points_expired' as expired_points
  from (select public.admin_expire_points() as r) s \gset
select tests.assert_eq_int(:'expired_points'::bigint, 15, 'vencimiento descuenta créditos antiguos');
select tests.assert_eq_int(
  (select coalesce(sum(points),0) from public.points_ledger where customer_id = '00000000-0000-4000-8000-000000000003'),
  20,
  'saldo restante tras vencimiento'
);
select tests.assert_eq_int(
  (select (public.admin_expire_points()->>'points_expired')::bigint),
  0,
  'vencimiento es idempotente'
);
select public.admin_update_settings('{"points_expiry_days":null}'::jsonb);

-- ---------------------------------------------------------------------
-- Resumen final
-- ---------------------------------------------------------------------
select tests.assert_eq_int(
  (select coalesce(sum(points),0) from public.points_ledger where customer_id = '00000000-0000-4000-8000-000000000004'),
  58,
  'saldo final del cliente 2 consistente'
);
select tests.assert(
  (select count(*) from public.redemptions where code = :'redeem1_code') = 1,
  'código de canje único'
);

rollback;

\echo '== Todas las aserciones SQL pasaron =='
