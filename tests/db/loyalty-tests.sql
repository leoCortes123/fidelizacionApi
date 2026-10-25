-- =====================================================================
-- Fase 7 — Pruebas de aceptación de punta a punta (20 casos)
--
-- Complementa a `loyalty-phase0-tests.sql`: recorre los escenarios del
-- prompt original en orden, con datos deterministas y sin servicios
-- externos. Todo ocurre en una transacción que se revierte al final, así
-- que puede ejecutarse sobre la base de pruebas sin dejar rastro.
--
-- Casos:
--   1. Registro de negocio (valores por defecto y slug duplicado)
--   2. Roles por negocio (admin, encargado, cliente y últimos admin)
--   3. Aislamiento entre negocios y RLS
--   4. Recompensas (validaciones de creación)
--   5. Acumulación de puntos por compra
--   6. Reverso de compra
--   7. Duplicados e idempotencia
--   8. Saldo insuficiente
--   9. Reserva y liberación de puntos
--  10. QR vigente
--  11. QR vencido
--  12. QR reutilizado y reemisión
--  13. Doble aprobación (serialización; la concurrencia real la ejecuta
--      `scripts/test-db.sh` con dos conexiones)
--  14. Vencimiento de puntos por lote (FIFO)
--  15. Presupuesto y panel económico
--  16. Datos económicos incompletos
--  17. Límites de descuento y de canjes
--  18. Acceso a datos ajenos
--  19. Campañas con vigencia y mínimo de compra
--  20. Snapshots mensuales reproducibles y permisos de servicio
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

-- Usuarios de prueba (el trigger crea perfiles y el rol customer).
insert into auth.users (id, email, raw_user_meta_data) values
  ('20000000-0000-4000-8000-000000000001', 'casos-a@example.test', '{"full_name":"Dueña A"}'),
  ('20000000-0000-4000-8000-000000000002', 'casos-b@example.test', '{"full_name":"Dueño B"}'),
  ('20000000-0000-4000-8000-000000000003', 'casos-encargado@example.test', '{"full_name":"Encargado A"}'),
  ('20000000-0000-4000-8000-000000000004', 'casos-encargado-sin-permiso@example.test', '{"full_name":"Encargado Sin Permiso"}'),
  ('20000000-0000-4000-8000-000000000005', 'casos-cliente@example.test', '{"full_name":"Cliente Uno"}'),
  ('20000000-0000-4000-8000-000000000006', 'casos-cliente2@example.test', '{"full_name":"Cliente Dos"}');

set local role authenticated;

-- =====================================================================
-- Caso 1 — Registro de negocio
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000001');
select r->>'business_id' as biz_a
  from (select public.business_register('Casos Negocio A', 'casos-negocio-a') as r) s \gset

select tests.assert(:'biz_a' <> '', 'caso 1: el registro devuelve el negocio');
select tests.assert_eq_int(
  (select count(*) from public.loyalty_programs where business_id = :'biz_a'::uuid),
  1,
  'caso 1: el registro crea el programa de puntos'
);
select tests.assert_eq_int(
  (select count(*) from public.business_economic_profiles where business_id = :'biz_a'::uuid),
  1,
  'caso 1: el registro crea el perfil económico'
);
select tests.assert(
  not (select is_active from public.loyalty_programs where business_id = :'biz_a'::uuid),
  'caso 1: el programa nace inactivo'
);
select tests.assert_eq_int(
  (select cop_per_point_unit from public.loyalty_programs where business_id = :'biz_a'::uuid),
  1000,
  'caso 1: el programa nace con 1 punto por 1000 COP'
);
select tests.assert_eq_text(
  (select role::text from public.businesses_list() where id = :'biz_a'::uuid),
  'admin',
  'caso 1: quien registra queda como administrador'
);
select tests.expect_error(
  $$select public.business_register('Otro nombre', 'casos-negocio-a')$$,
  'business_slug_duplicate'
);
select tests.expect_error(
  $$select public.business_register('X', 'slug-invalido')$$,
  'invalid_business_name'
);

-- Programa activo: 1 punto por cada 1000 COP y presupuesto del 1 %.
select public.loyalty_program_configure(
  p_business_id => :'biz_a'::uuid,
  p_cop_per_point_unit => 1000,
  p_points_per_cop_unit => 100,
  p_points_expiry_days => 365,
  p_budget_rate => 0.01,
  p_first_purchase_bonus_points => 0,
  p_recurrence_bonus_points => 0,
  p_referral_bonus_points => 0,
  p_qr_expiry_hours => 24,
  p_is_active => true
);
select tests.assert(
  (select is_active from public.loyalty_programs where business_id = :'biz_a'::uuid),
  'caso 1: el administrador activa el programa'
);

-- Carta y recompensas de apoyo.
select r->>'id' as product_a
  from (
    select public.product_upsert(
      p_business_id => :'biz_a'::uuid,
      p_name => 'Taco de casos',
      p_price_cop => 12000,
      p_cost_cop => 4000,
      p_is_active => true
    ) as r
  ) s \gset

select r->>'id' as reward_free
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz_a'::uuid,
      p_type => 'free_product',
      p_name => 'Taco gratis',
      p_points_required => 10,
      p_product_id => :'product_a'::uuid,
      p_is_active => true
    ) as r
  ) s \gset

select r->>'id' as reward_qr
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz_a'::uuid,
      p_type => 'free_product',
      p_name => 'Taco QR',
      p_points_required => 10,
      p_product_id => :'product_a'::uuid,
      p_is_active => true
    ) as r
  ) s \gset

select r->>'id' as reward_customer
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz_a'::uuid,
      p_type => 'fixed_discount',
      p_name => 'Descuento por cliente',
      p_points_required => 1,
      p_min_purchase_amount => 2000,
      p_max_discount_amount => 1000,
      p_max_redemptions_per_customer => 1,
      p_is_active => true
    ) as r
  ) s \gset

select r->>'id' as reward_period
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz_a'::uuid,
      p_type => 'fixed_discount',
      p_name => 'Descuento por periodo',
      p_points_required => 1,
      p_min_purchase_amount => 2000,
      p_max_discount_amount => 1000,
      p_max_redemptions_per_period => 1,
      p_redemption_period_days => 30,
      p_is_active => true
    ) as r
  ) s \gset

select r->>'id' as reward_total
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz_a'::uuid,
      p_type => 'fixed_discount',
      p_name => 'Descuento limitado',
      p_points_required => 1,
      p_min_purchase_amount => 2000,
      p_max_discount_amount => 1000,
      p_total_redemption_limit => 1,
      p_is_active => true
    ) as r
  ) s \gset

-- =====================================================================
-- Caso 2 — Roles por negocio
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000002');
select r->>'business_id' as biz_b
  from (select public.business_register('Casos Negocio B', 'casos-negocio-b') as r) s \gset
select public.loyalty_program_configure(
  p_business_id => :'biz_b'::uuid,
  p_cop_per_point_unit => 1000,
  p_points_per_cop_unit => 100,
  p_points_expiry_days => 365,
  p_budget_rate => 0.01,
  p_first_purchase_bonus_points => 0,
  p_recurrence_bonus_points => 0,
  p_referral_bonus_points => 0,
  p_qr_expiry_hours => 24,
  p_is_active => true
);
select r->>'id' as reward_b
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz_b'::uuid,
      p_type => 'fixed_discount',
      p_name => 'Descuento negocio B',
      p_points_required => 5,
      p_min_purchase_amount => 2000,
      p_max_discount_amount => 1000,
      p_is_active => true
    ) as r
  ) s \gset

select tests.as_user('20000000-0000-4000-8000-000000000005');
select public.business_join('casos-negocio-a');
select tests.as_user('20000000-0000-4000-8000-000000000006');
select public.business_join('casos-negocio-a');

select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.business_membership_create(
  p_business_id => :'biz_a'::uuid,
  p_user_id => '20000000-0000-4000-8000-000000000003',
  p_role => 'encargado',
  p_can_approve_redemptions => true
);
select public.business_membership_create(
  p_business_id => :'biz_a'::uuid,
  p_user_id => '20000000-0000-4000-8000-000000000004',
  p_role => 'encargado',
  p_can_approve_redemptions => false
);

select tests.assert(
  'admin' = any (public.get_my_app_roles()),
  'caso 2: la administradora recibe admin'
);
select tests.as_user('20000000-0000-4000-8000-000000000003');
select tests.assert(
  'registrar' = any (public.get_my_app_roles()),
  'caso 2: el encargado recibe registrar'
);
select tests.as_user('20000000-0000-4000-8000-000000000005');
select tests.assert(
  'customer' = any (public.get_my_app_roles()),
  'caso 2: el cliente conserva customer'
);
select tests.assert_eq_text(
  (select role::text from public.businesses_list() where id = :'biz_a'::uuid),
  'cliente',
  'caso 2: businesses_list devuelve el rol del cliente'
);

select tests.as_user('20000000-0000-4000-8000-000000000001');
select tests.expect_error(
  format(
    $$select public.business_membership_create(%L::uuid, %L::uuid, 'encargado', false)$$,
    :'biz_a', '20000000-0000-4000-8000-000000000001'
  ),
  'last_admin'
);

select tests.as_user('20000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.business_membership_create(%L::uuid, %L::uuid, 'cliente', false)$$,
         :'biz_a', '20000000-0000-4000-8000-000000000005'),
  'forbidden'
);
select tests.expect_error(
  format($$select public.loyalty_program_configure(%L::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true)$$,
         :'biz_a'),
  'forbidden'
);

select tests.as_user('20000000-0000-4000-8000-000000000005');
select tests.expect_error(
  format($$select public.loyalty_program_configure(%L::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true)$$,
         :'biz_a'),
  'forbidden'
);

-- =====================================================================
-- Caso 3 — Aislamiento entre negocios
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000002');
select tests.assert_eq_int(
  (select count(*) from public.businesses_list()),
  1,
  'caso 3: el dueño B solo ve su negocio'
);
select tests.expect_error(
  format($$select public.loyalty_program_get(%L::uuid)$$, :'biz_a'),
  'business_not_found_or_no_access'
);
select tests.expect_error(
  format($$select public.loyalty_rewards_list(%L::uuid, true)$$, :'biz_a'),
  'business_not_found_or_no_access'
);
select tests.expect_error(
  format($$select public.loyalty_redemptions_list(%L::uuid, null, 10, 0)$$, :'biz_a'),
  'business_not_found_or_no_access'
);

select tests.as_user('20000000-0000-4000-8000-000000000005');
select tests.assert_eq_int(
  (select count(*) from public.loyalty_rewards where business_id = :'biz_b'::uuid),
  0,
  'caso 3: RLS oculta recompensas de otro negocio'
);
select tests.expect_error(
  format($$insert into public.loyalty_rewards (business_id, type, name, points_required)
           values (%L::uuid, 'fixed_discount', 'Intruso', 5)$$, :'biz_b'),
  'permission denied'
);

-- =====================================================================
-- Caso 4 — Recompensas: validaciones
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000001');
select tests.expect_error(
  format($$select public.loyalty_reward_upsert(%L::uuid, 'free_product', 'Sin producto', 5)$$,
         :'biz_a'),
  'free_product_requires_product'
);
select tests.expect_error(
  format($$select public.loyalty_reward_upsert(%L::uuid, 'fixed_discount', 'Puntos cero', 0, null, null, '', 0, 1000)$$,
         :'biz_a'),
  'invalid_reward_points'
);
select tests.expect_error(
  format($$select public.loyalty_reward_upsert(%L::uuid, 'percentage_discount', 'Sin porcentaje', 5, null, null, '', 10000, 5000)$$,
         :'biz_a'),
  'invalid_discount_percentage'
);
select tests.expect_error(
  format($$select public.loyalty_reward_upsert(%L::uuid, 'fixed_discount', 'Sin importe', 5, null, null, '', 2000, null)$$,
         :'biz_a'),
  'invalid_max_discount'
);
select tests.expect_error(
  format($$select public.loyalty_reward_upsert(%L::uuid, 'fixed_discount', 'Periodo sin días', 5, null, null, '', 2000, 1000, null, null, null, null, 1, null)$$,
         :'biz_a'),
  'invalid_redemption_period'
);
select tests.expect_error(
  format($$select public.loyalty_reward_upsert(%L::uuid, 'fixed_discount', 'Recompensa de B', 5, %L::uuid, null, '', 2000, 1000)$$,
         :'biz_a', :'reward_b'),
  'reward_not_found'
);

-- El beneficio configurable conserva el importe definido por el admin.
select public.loyalty_reward_upsert(
  p_business_id => :'biz_a'::uuid,
  p_type => 'configurable_benefit',
  p_name => 'Beneficio configurable',
  p_points_required => 5,
  p_min_purchase_amount => 5000,
  p_max_discount_amount => 3000,
  p_is_active => true
);
select tests.assert_eq_int(
  (select max_discount_amount from public.loyalty_rewards
    where business_id = :'biz_a'::uuid and name = 'Beneficio configurable'),
  3000,
  'caso 4: el beneficio configurable conserva su importe'
);

-- =====================================================================
-- Caso 5 — Acumulación por compra
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000001');
select tests.assert_eq_int(
  ((public.loyalty_purchase_register(
    p_business_id => :'biz_a'::uuid,
    p_customer_id => '20000000-0000-4000-8000-000000000005',
    p_amount_cop => 15500,
    p_eligible_amount_cop => 15500,
    p_idempotency_key => 'casos-compra-0001'
  ))->>'points_earned')::integer,
  15,
  'caso 5: floor(15500/1000) = 15 puntos'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005'
  ))->>'balance')::bigint,
  15,
  'caso 5: el saldo refleja los puntos acumulados'
);
select tests.assert(
  exists (
    select 1 from public.business_audit_log_page(:'biz_a'::uuid, 'purchase.registered', 50, 0)
  ),
  'caso 5: la compra queda auditada'
);
select tests.assert(
  exists (
    select 1 from public.loyalty_point_transactions
     where business_id = :'biz_a'::uuid
       and movement_type = 'purchase_credit'
       and points = 15
  ),
  'caso 5: el libro registra el crédito de compra'
);
select tests.as_user('20000000-0000-4000-8000-000000000005');
select tests.assert(
  exists (
    select 1 from public.loyalty_account_transactions(
      :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005', 10, 0
    ) where points = 15
  ),
  'caso 5: el cliente ve su historial de puntos'
);

-- =====================================================================
-- Caso 6 — Reverso de compra
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000001');
select r->>'purchase_event_id' as event_revert
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'biz_a'::uuid,
      p_customer_id => '20000000-0000-4000-8000-000000000005',
      p_amount_cop => 5000,
      p_eligible_amount_cop => 5000,
      p_idempotency_key => 'casos-compra-0002'
    ) as r
  ) s \gset
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005'
  ))->>'balance')::bigint,
  20,
  'caso 6: la segunda compra suma 5 puntos'
);
select tests.assert_eq_int(
  ((public.loyalty_purchase_revert(
    p_business_id => :'biz_a'::uuid,
    p_event_id => :'event_revert'::uuid,
    p_reason => 'Cobro duplicado'
  ))->>'points_reversed')::integer,
  5,
  'caso 6: el reverso devuelve 5 puntos'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005'
  ))->>'balance')::bigint,
  15,
  'caso 6: el saldo vuelve al valor anterior'
);
select tests.assert(
  ((public.loyalty_purchase_revert(
    p_business_id => :'biz_a'::uuid,
    p_event_id => :'event_revert'::uuid,
    p_reason => 'Reverso repetido'
  ))->>'duplicate')::boolean,
  'caso 6: el reverso es idempotente'
);
select tests.assert(
  exists (
    select 1 from public.business_audit_log_page(:'biz_a'::uuid, 'purchase.reverted', 50, 0)
  ),
  'caso 6: el reverso queda auditado'
);

-- =====================================================================
-- Caso 7 — Duplicados e idempotencia
-- =====================================================================
select tests.assert(
  ((public.loyalty_purchase_register(
    p_business_id => :'biz_a'::uuid,
    p_customer_id => '20000000-0000-4000-8000-000000000005',
    p_amount_cop => 15500,
    p_eligible_amount_cop => 15500,
    p_idempotency_key => 'casos-compra-0001'
  ))->>'duplicate')::boolean,
  'caso 7: repetir la compra con la misma clave no duplica'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005'
  ))->>'balance')::bigint,
  15,
  'caso 7: el saldo no cambia al repetir'
);
select tests.expect_error(
  format(
    $$select public.loyalty_purchase_register(
        %L::uuid, %L::uuid, 15500, 15500, 'casos-compra-0001'
      )$$,
    :'biz_a', '20000000-0000-4000-8000-000000000006'
  ),
  'idempotency_key_conflict'
);

-- =====================================================================
-- Caso 8 — Saldo insuficiente
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000006');
select tests.expect_error(
  format(
    $$select public.reward_request_redemption(%L::uuid, %L::uuid, 'casos-sin-saldo-0001')$$,
    :'biz_a', :'reward_free'
  ),
  'insufficient_points'
);
select tests.assert_eq_int(
  (select count(*) from public.loyalty_redemptions
    where business_id = :'biz_a'::uuid
      and account_id = (
        select id from public.loyalty_point_accounts
         where business_id = :'biz_a'::uuid
           and customer_id = '20000000-0000-4000-8000-000000000006'
      )),
  0,
  'caso 8: una solicitud rechazada no crea redención'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000006'
  ))->>'balance')::bigint,
  0,
  'caso 8: el saldo del cliente sin puntos sigue en cero'
);

-- =====================================================================
-- Caso 9 — Reserva y liberación
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red_reserve,
       r->>'token' as token_reserve
  from (
    select public.reward_request_redemption(
      :'biz_a'::uuid, :'reward_free'::uuid, 'casos-canje-0001'
    ) as r
  ) s \gset
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005'
  ))->>'balance')::bigint,
  5,
  'caso 9: la solicitud reserva 10 puntos'
);
select tests.assert_eq_text(
  (public.reward_request_redemption(
    :'biz_a'::uuid, :'reward_free'::uuid, 'casos-canje-0001'
  ))->>'redemption_id',
  :'red_reserve',
  'caso 9: repetir la solicitud devuelve la misma redención'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005'
  ))->>'balance')::bigint,
  5,
  'caso 9: la solicitud idempotente no vuelve a reservar'
);

select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.redemption_cancel(
  :'biz_a'::uuid, :'red_reserve'::uuid, 'Cancelada por el cliente'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005'
  ))->>'balance')::bigint,
  15,
  'caso 9: cancelar libera los 10 puntos'
);

select tests.as_user('20000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red_deliver
  from (
    select public.reward_request_redemption(
      :'biz_a'::uuid, :'reward_free'::uuid, 'casos-canje-0002'
    ) as r
  ) s \gset
select tests.as_user('20000000-0000-4000-8000-000000000003');
select public.redemption_approve(:'biz_a'::uuid, :'red_deliver'::uuid, true);
select public.redemption_deliver(:'biz_a'::uuid, :'red_deliver'::uuid);
select tests.as_user('20000000-0000-4000-8000-000000000005');
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005'
  ))->>'balance')::bigint,
  5,
  'caso 9: la entrega consume los puntos reservados'
);
select tests.assert_eq_text(
  (select status::text from public.loyalty_my_redemptions() where id = :'red_deliver'::uuid),
  'delivered',
  'caso 9: el cliente ve su canje entregado'
);

-- =====================================================================
-- Caso 10 — QR vigente
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.loyalty_purchase_register(
  p_business_id => :'biz_a'::uuid,
  p_customer_id => '20000000-0000-4000-8000-000000000005',
  p_amount_cop => 10000,
  p_eligible_amount_cop => 10000,
  p_idempotency_key => 'casos-compra-0003'
);

select tests.as_user('20000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red_qr1,
       r->>'token' as token_qr1
  from (
    select public.reward_request_redemption(
      :'biz_a'::uuid, :'reward_qr'::uuid, 'casos-qr-0001'
    ) as r
  ) s \gset
select tests.assert(length(:'token_qr1') >= 20, 'caso 10: la solicitud genera un token QR');

select tests.as_user('20000000-0000-4000-8000-000000000003');
select tests.assert_eq_text(
  (public.redemption_token_validate(:'biz_a'::uuid, :'token_qr1'))->>'status',
  'pending',
  'caso 10: el encargado valida un QR vigente'
);
select tests.assert_eq_text(
  (public.redemption_token_validate(:'biz_a'::uuid, :'token_qr1'))->>'customer_id',
  '20000000-0000-4000-8000-000000000005',
  'caso 10: el QR identifica al cliente sin exponer datos personales'
);
select tests.assert(
  ((public.redemption_token_validate(:'biz_a'::uuid, :'token_qr1'))->>'can_approve')::boolean,
  'caso 10: el encargado con permiso puede aprobar'
);

-- =====================================================================
-- Caso 11 — QR vencido
-- =====================================================================
reset role;
update public.loyalty_redemption_tokens
   set expires_at = now() - interval '1 minute'
 where redemption_id = :'red_qr1'::uuid;
set local role authenticated;

select tests.as_user('20000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.redemption_token_validate(%L::uuid, %L)$$, :'biz_a', :'token_qr1'),
  'token_expired'
);
select tests.expect_error(
  format($$select public.redemption_approve(%L::uuid, %L::uuid, true)$$, :'biz_a', :'red_qr1'),
  'token_expired'
);

select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.redemption_cancel(:'biz_a'::uuid, :'red_qr1'::uuid, 'QR vencido');
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000005'
  ))->>'balance')::bigint,
  15,
  'caso 11: cancelar un QR vencido libera los puntos'
);

-- =====================================================================
-- Caso 12 — QR reutilizado y reemisión
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red_qr2,
       r->>'token' as token_qr2
  from (
    select public.reward_request_redemption(
      :'biz_a'::uuid, :'reward_qr'::uuid, 'casos-qr-0002'
    ) as r
  ) s \gset
select tests.as_user('20000000-0000-4000-8000-000000000003');
select public.redemption_approve(:'biz_a'::uuid, :'red_qr2'::uuid, true);
select public.redemption_deliver(:'biz_a'::uuid, :'red_qr2'::uuid);
select tests.expect_error(
  format($$select public.redemption_token_validate(%L::uuid, %L)$$, :'biz_a', :'token_qr2'),
  'redemption_not_pending'
);
select tests.expect_error(
  format($$select public.redemption_approve(%L::uuid, %L::uuid, true)$$, :'biz_a', :'red_qr2'),
  'redemption_not_pending'
);

select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.loyalty_purchase_register(
  p_business_id => :'biz_a'::uuid,
  p_customer_id => '20000000-0000-4000-8000-000000000005',
  p_amount_cop => 10000,
  p_eligible_amount_cop => 10000,
  p_idempotency_key => 'casos-compra-0004'
);
select tests.as_user('20000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red_qr3,
       r->>'token' as token_qr3
  from (
    select public.reward_request_redemption(
      :'biz_a'::uuid, :'reward_qr'::uuid, 'casos-qr-0003'
    ) as r
  ) s \gset
select r->>'token' as token_qr3_new
  from (select public.redemption_token_reissue(:'red_qr3'::uuid) as r) s \gset

select tests.as_user('20000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.redemption_token_validate(%L::uuid, %L)$$, :'biz_a', :'token_qr3'),
  'invalid_token'
);
select public.redemption_approve(:'biz_a'::uuid, :'red_qr3'::uuid, true);
select public.redemption_deliver(:'biz_a'::uuid, :'red_qr3'::uuid);
select tests.expect_error(
  format($$select public.redemption_approve(%L::uuid, %L::uuid, true)$$, :'biz_a', :'red_qr3'),
  'redemption_not_pending'
);

-- =====================================================================
-- Caso 13 — Doble aprobación (serialización)
-- La concurrencia real con dos conexiones se ejecuta en test-db.sh.
-- =====================================================================
select tests.assert_eq_int(
  (select count(*) from public.business_audit_logs
    where business_id = :'biz_a'::uuid
      and operation = 'redemption.approved'
      and entity_id = :'red_qr3'),
  1,
  'caso 13: una redención se aprueba una sola vez'
);
select tests.assert_eq_int(
  (select count(*) from public.loyalty_redemption_tokens
    where redemption_id = :'red_qr3'::uuid and consumed_at is not null),
  1,
  'caso 13: solo un token queda consumido'
);

-- =====================================================================
-- Caso 14 — Vencimiento por lote (FIFO)
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.loyalty_purchase_register(
  p_business_id => :'biz_a'::uuid,
  p_customer_id => '20000000-0000-4000-8000-000000000006',
  p_amount_cop => 10000,
  p_eligible_amount_cop => 10000,
  p_idempotency_key => 'casos-exp-0001'
);
select public.loyalty_purchase_register(
  p_business_id => :'biz_a'::uuid,
  p_customer_id => '20000000-0000-4000-8000-000000000006',
  p_amount_cop => 20000,
  p_eligible_amount_cop => 20000,
  p_idempotency_key => 'casos-exp-0002'
);
select id as lot_old
  from public.loyalty_point_transactions
 where business_id = :'biz_a'::uuid
   and idempotency_key like '%casos-exp-0001' \gset

reset role;
update public.loyalty_point_transactions
   set created_at = now() - interval '40 days',
       expires_at = now() - interval '1 day'
 where id = :'lot_old'::uuid;
set local role authenticated;

select tests.as_user('20000000-0000-4000-8000-000000000001');
select r->>'lots_expired' as exp_lots,
       r->>'points_expired' as exp_points
  from (select public.points_expire_due(:'biz_a'::uuid) as r) s \gset
select tests.assert_eq_int(:'exp_lots'::integer, 1, 'caso 14: vence solo el lote antiguo');
select tests.assert_eq_int(:'exp_points'::integer, 10, 'caso 14: se descuentan 10 puntos');
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz_a'::uuid, '20000000-0000-4000-8000-000000000006'
  ))->>'balance')::bigint,
  20,
  'caso 14: el lote nuevo conserva sus 20 puntos'
);
select tests.assert_eq_int(
  (public.points_expire_due(:'biz_a'::uuid)->>'points_expired')::integer,
  0,
  'caso 14: el vencimiento es idempotente'
);
select tests.assert(
  exists (
    select 1 from public.loyalty_point_transactions
     where business_id = :'biz_a'::uuid
       and movement_type = 'expiry_debit'
       and idempotency_key = 'expiry:' || :'lot_old'
  ),
  'caso 14: el débito queda vinculado al lote vencido'
);

-- =====================================================================
-- Caso 15 — Presupuesto y panel económico
-- =====================================================================
select public.business_economic_profile_upsert(
  p_business_id => :'biz_a'::uuid,
  p_daily_avg_sales => 100000,
  p_monthly_operation_days => 30,
  p_daily_gain => 40000,
  p_gross_margin => 40,
  p_avg_customers_per_day => 25,
  p_max_monthly_reward_budget => 50000,
  p_data_status => '{"daily_avg_sales":"confirmed","monthly_operation_days":"confirmed"}'::jsonb
);
select tests.assert_eq_int(
  (public.business_dashboard_economic(:'biz_a'::uuid)->>'monthly_estimated_sales_cop')::bigint,
  3000000,
  'caso 15: ventas mensuales = 100000 × 30'
);
select tests.assert_eq_int(
  (public.business_dashboard_economic(:'biz_a'::uuid)->>'reference_budget_cop')::bigint,
  30000,
  'caso 15: presupuesto de referencia = ventas × 1 %'
);
select tests.assert_eq_int(
  (public.business_dashboard_economic(:'biz_a'::uuid)->>'max_monthly_reward_budget_cop')::bigint,
  50000,
  'caso 15: se respeta el presupuesto máximo configurado'
);
select tests.assert_eq_int(
  (public.business_dashboard_economic(:'biz_a'::uuid)->>'redeemed_rewards_cost_cop')::bigint,
  360000,
  'caso 15: costo redimido = 3 canjes entregados × 10 puntos × 12000 COP'
);
select tests.assert_eq_int(
  (public.business_dashboard_economic(:'biz_a'::uuid)->>'remaining_budget_cop')::bigint,
  0,
  'caso 15: el presupuesto restante nunca es negativo'
);
select tests.assert(
  (public.business_dashboard_economic(:'biz_a'::uuid)->>'budget_committed_percent')::numeric = 720,
  'caso 15: el porcentaje comprometido cuadra con el costo redimido'
);

-- =====================================================================
-- Caso 16 — Datos económicos incompletos
-- =====================================================================
select public.business_economic_profile_upsert(
  p_business_id => :'biz_a'::uuid,
  p_daily_avg_sales => null,
  p_monthly_operation_days => 30,
  p_daily_gain => null,
  p_gross_margin => null,
  p_avg_customers_per_day => null,
  p_max_monthly_reward_budget => 50000,
  p_data_status => '{"daily_avg_sales":"unknown"}'::jsonb
);
select tests.assert(
  (public.business_economic_profile_get(:'biz_a'::uuid))->>'daily_avg_sales' is null,
  'caso 16: marcar un dato como desconocido lo limpia'
);
select tests.assert(
  (public.business_dashboard_economic(:'biz_a'::uuid)->>'estimated')::boolean,
  'caso 16: el panel marca los indicadores como estimados'
);
select tests.assert_eq_int(
  (public.business_dashboard_economic(:'biz_a'::uuid)->>'monthly_estimated_sales_cop')::bigint,
  0,
  'caso 16: sin ventas diarias no se inventan ventas mensuales'
);
select tests.expect_error(
  format(
    $$select public.business_economic_profile_upsert(%L::uuid, 100000, 40, null, null, null, 50000)$$,
    :'biz_a'
  ),
  'invalid_operation_days'
);

-- Restaurar datos completos para los casos siguientes.
select public.business_economic_profile_upsert(
  p_business_id => :'biz_a'::uuid,
  p_daily_avg_sales => 100000,
  p_monthly_operation_days => 30,
  p_daily_gain => 40000,
  p_gross_margin => 40,
  p_avg_customers_per_day => 25,
  p_max_monthly_reward_budget => 50000,
  p_data_status => '{"daily_avg_sales":"confirmed","monthly_operation_days":"confirmed"}'::jsonb
);

-- =====================================================================
-- Caso 17 — Límites de descuento y de canjes
-- =====================================================================
select tests.expect_error(
  format($$select public.loyalty_reward_upsert(%L::uuid, 'percentage_discount', 'Porcentaje inválido', 5, null, null, '', 10000, 5000, 101)$$,
         :'biz_a'),
  'invalid_discount_percentage'
);
select tests.expect_error(
  format($$select public.loyalty_reward_upsert(%L::uuid, 'fixed_discount', 'Descuento mayor que el mínimo', 5, null, null, '', 5000, 6000)$$,
         :'biz_a'),
  'discount_exceeds_min_purchase'
);
select tests.expect_error(
  format($$select public.loyalty_reward_upsert(%L::uuid, 'percentage_discount', 'Porcentaje válido', 5, null, null, '', 10000, 5000, 15, null, null, null, null, null, 0)$$,
         :'biz_a'),
  'invalid_redemption_limit'
);

-- Límite por cliente: el segundo canje pendiente se rechaza.
select tests.as_user('20000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red_customer
  from (
    select public.reward_request_redemption(
      :'biz_a'::uuid, :'reward_customer'::uuid, 'casos-limite-cliente-01'
    ) as r
  ) s \gset
select tests.expect_error(
  format(
    $$select public.reward_request_redemption(%L::uuid, %L::uuid, 'casos-limite-cliente-02')$$,
    :'biz_a', :'reward_customer'
  ),
  'reward_customer_limit_reached'
);
select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.redemption_cancel(:'biz_a'::uuid, :'red_customer'::uuid, 'Fin del caso por cliente');

-- Límite por periodo.
select tests.as_user('20000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red_period
  from (
    select public.reward_request_redemption(
      :'biz_a'::uuid, :'reward_period'::uuid, 'casos-limite-periodo-01'
    ) as r
  ) s \gset
select tests.expect_error(
  format(
    $$select public.reward_request_redemption(%L::uuid, %L::uuid, 'casos-limite-periodo-02')$$,
    :'biz_a', :'reward_period'
  ),
  'reward_period_limit_reached'
);
select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.redemption_cancel(:'biz_a'::uuid, :'red_period'::uuid, 'Fin del caso por periodo');

-- Límite total del negocio.
select tests.as_user('20000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red_total
  from (
    select public.reward_request_redemption(
      :'biz_a'::uuid, :'reward_total'::uuid, 'casos-limite-total-01'
    ) as r
  ) s \gset
select tests.as_user('20000000-0000-4000-8000-000000000006');
select tests.expect_error(
  format(
    $$select public.reward_request_redemption(%L::uuid, %L::uuid, 'casos-limite-total-02')$$,
    :'biz_a', :'reward_total'
  ),
  'reward_total_limit_reached'
);
select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.redemption_cancel(:'biz_a'::uuid, :'red_total'::uuid, 'Fin del caso total');

-- =====================================================================
-- Caso 18 — Acceso a datos ajenos
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red_foreign,
       r->>'token' as token_foreign
  from (
    select public.reward_request_redemption(
      :'biz_a'::uuid, :'reward_customer'::uuid, 'casos-ajeno-0001'
    ) as r
  ) s \gset

select tests.as_user('20000000-0000-4000-8000-000000000006');
select tests.expect_error(
  format($$select public.redemption_token_validate(%L::uuid, %L)$$, :'biz_a', :'token_foreign'),
  'forbidden'
);
select tests.expect_error(
  format($$select public.redemption_approve(%L::uuid, %L::uuid, true)$$, :'biz_a', :'red_foreign'),
  'forbidden'
);
select tests.expect_error(
  format($$select public.loyalty_redemptions_list(%L::uuid, null, 10, 0)$$, :'biz_a'),
  'forbidden'
);
select tests.expect_error(
  format($$select public.loyalty_account_transactions(%L::uuid, %L::uuid, 10, 0)$$,
         :'biz_a', '20000000-0000-4000-8000-000000000005'),
  'forbidden'
);

select tests.as_user('20000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format($$select public.redemption_token_validate(%L::uuid, %L)$$, :'biz_a', :'token_foreign'),
  'forbidden'
);

select tests.as_user('20000000-0000-4000-8000-000000000002');
select tests.expect_error(
  format($$select public.redemption_token_validate(%L::uuid, %L)$$, :'biz_b', :'token_foreign'),
  'forbidden'
);

select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.redemption_cancel(:'biz_a'::uuid, :'red_foreign'::uuid, 'Fin del caso ajeno');

-- =====================================================================
-- Caso 19 — Campañas con vigencia y mínimo
-- =====================================================================
select r->>'id' as campaign_double
  from (
    select public.loyalty_campaign_upsert(
      p_business_id => :'biz_a'::uuid,
      p_name => 'Doble puntos de casos',
      p_multiplier => 2,
      p_bonus_points => 0,
      p_min_purchase_amount => 0,
      p_valid_from => now() - interval '1 hour',
      p_valid_until => now() + interval '1 day',
      p_is_active => true
    ) as r
  ) s \gset

select r->>'points_earned' as campaign_points,
       r->>'base_points' as campaign_base,
       r->>'campaign_id' as campaign_applied
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'biz_a'::uuid,
      p_customer_id => '20000000-0000-4000-8000-000000000006',
      p_amount_cop => 10000,
      p_eligible_amount_cop => 10000,
      p_idempotency_key => 'casos-camp-0001'
    ) as r
  ) s \gset
select tests.assert_eq_int(:'campaign_base'::integer, 10, 'caso 19: la campaña conserva los puntos base');
select tests.assert_eq_int(:'campaign_points'::integer, 20, 'caso 19: la campaña duplica los puntos');
select tests.assert_eq_text(:'campaign_applied', :'campaign_double', 'caso 19: se registra la campaña aplicada');

select public.loyalty_campaign_upsert(
  p_business_id => :'biz_a'::uuid,
  p_name => 'Doble puntos de casos',
  p_multiplier => 2,
  p_bonus_points => 0,
  p_min_purchase_amount => 0,
  p_valid_from => now() - interval '1 hour',
  p_valid_until => now() + interval '1 day',
  p_is_active => false,
  p_id => :'campaign_double'::uuid
);
select public.loyalty_campaign_upsert(
  p_business_id => :'biz_a'::uuid,
  p_name => 'Campaña futura de casos',
  p_multiplier => 5,
  p_bonus_points => 0,
  p_min_purchase_amount => 0,
  p_valid_from => now() + interval '1 day',
  p_valid_until => now() + interval '2 days',
  p_is_active => true
);
select tests.assert_eq_int(
  ((public.loyalty_purchase_register(
    p_business_id => :'biz_a'::uuid,
    p_customer_id => '20000000-0000-4000-8000-000000000006',
    p_amount_cop => 10000,
    p_eligible_amount_cop => 10000,
    p_idempotency_key => 'casos-camp-0002'
  ))->>'points_earned')::integer,
  10,
  'caso 19: una campaña inactiva o futura no se aplica'
);

select public.loyalty_campaign_upsert(
  p_business_id => :'biz_a'::uuid,
  p_name => 'Bono de casos',
  p_multiplier => 1,
  p_bonus_points => 5,
  p_min_purchase_amount => 5000,
  p_valid_from => now() - interval '1 hour',
  p_valid_until => now() + interval '1 day',
  p_is_active => true
);
select tests.assert_eq_int(
  ((public.loyalty_purchase_register(
    p_business_id => :'biz_a'::uuid,
    p_customer_id => '20000000-0000-4000-8000-000000000006',
    p_amount_cop => 6000,
    p_eligible_amount_cop => 6000,
    p_idempotency_key => 'casos-camp-0003'
  ))->>'points_earned')::integer,
  11,
  'caso 19: el bono fijo aplica al cumplir la compra mínima'
);

select tests.as_user('20000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.loyalty_campaign_upsert(%L::uuid, 'Campaña intrusa', 2)$$, :'biz_a'),
  'forbidden'
);

-- =====================================================================
-- Caso 20 — Snapshots reproducibles y permisos de servicio
-- =====================================================================
select tests.as_user('20000000-0000-4000-8000-000000000001');
select r->>'id' as snapshot_first,
       r->>'period_start' as snapshot_period,
       r->>'monthly_sales_cop' as snapshot_sales,
       r->>'reference_budget_cop' as snapshot_reference,
       r->>'max_budget_cop' as snapshot_max
  from (
    select public.loyalty_budget_snapshot_create(
      :'biz_a'::uuid, date_trunc('month', now())::date
    ) as r
  ) s \gset
select tests.assert_eq_int(:'snapshot_sales'::bigint, 3000000, 'caso 20: el snapshot calcula las ventas mensuales');
select tests.assert_eq_int(:'snapshot_reference'::bigint, 30000, 'caso 20: el snapshot calcula el presupuesto de referencia');
select tests.assert_eq_int(:'snapshot_max'::bigint, 50000, 'caso 20: el snapshot respeta el presupuesto máximo');

select r->>'id' as snapshot_second
  from (
    select public.loyalty_budget_snapshot_create(
      :'biz_a'::uuid, date_trunc('month', now())::date
    ) as r
  ) s \gset
select tests.assert_eq_text(:'snapshot_second', :'snapshot_first', 'caso 20: repetir el snapshot actualiza la misma fila');
select tests.assert_eq_int(
  (select count(*) from public.loyalty_budget_snapshots
    where business_id = :'biz_a'::uuid and period_start = :'snapshot_period'::date),
  1,
  'caso 20: solo existe un snapshot por mes'
);

select tests.as_user('20000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.loyalty_budget_snapshot_create(%L::uuid, current_date)$$, :'biz_a'),
  'forbidden'
);
select tests.expect_error(
  $$select public.points_expire_all_due()$$,
  'permission denied'
);
select tests.expect_error(
  $$select public.loyalty_budget_snapshot_all(current_date)$$,
  'permission denied'
);

rollback;

\echo '== Pruebas de aceptación de Fase 7 completadas (20 casos) =='
