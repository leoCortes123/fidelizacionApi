-- =====================================================================
-- Loopoint F6 — Canje escaneado por QR (M5)
--
--  1. Contexto del token sin business_id (negocio resuelto en servidor)
--  2. Permisos: solo admin/encargado autorizado del negocio del token
--  3. Confirmación de entrega atómica y consumo del token
--  4. Token reutilizado, vencido y token inexistente
--  5. Origen `manual` vs. `qr_scan` en el listado y su filtro
--  6. Auditoría del escaneo
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('70000000-0000-4000-8000-000000000001', 'f6-admin@example.test', '{"full_name":"Admin F6"}'),
  ('70000000-0000-4000-8000-000000000002', 'f6-encargado@example.test', '{"full_name":"Encargado F6"}'),
  ('70000000-0000-4000-8000-000000000003', 'f6-sin-permiso@example.test', '{"full_name":"Sin Permiso F6"}'),
  ('70000000-0000-4000-8000-000000000004', 'f6-cliente@example.test', '{"full_name":"Cliente F6"}'),
  ('70000000-0000-4000-8000-000000000005', 'f6-cliente2@example.test', '{"full_name":"Cliente Dos F6"}'),
  ('70000000-0000-4000-8000-000000000006', 'f6-cliente3@example.test', '{"full_name":"Cliente Tres F6"}'),
  ('70000000-0000-4000-8000-000000000007', 'f6-ajeno@example.test', '{"full_name":"Admin Ajeno F6"}');

set local role authenticated;
select tests.as_user('70000000-0000-4000-8000-000000000001');

select r->>'business_id' as biz
  from (select public.business_register('Negocio F6', 'negocio-f6') as r) s \gset

select public.business_membership_create(
  :'biz'::uuid, '70000000-0000-4000-8000-000000000002', 'encargado', true
);
select public.business_membership_create(
  :'biz'::uuid, '70000000-0000-4000-8000-000000000003', 'encargado', false
);
select public.business_membership_create(
  :'biz'::uuid, '70000000-0000-4000-8000-000000000004', 'cliente', false
);
select public.business_membership_create(
  :'biz'::uuid, '70000000-0000-4000-8000-000000000005', 'cliente', false
);
select public.business_membership_create(
  :'biz'::uuid, '70000000-0000-4000-8000-000000000006', 'cliente', false
);

select public.loyalty_program_configure(
  :'biz'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);

select r->>'id' as reward_id
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz'::uuid,
      p_type => 'configurable_benefit',
      p_name => 'Postre F6',
      p_points_required => 10,
      p_min_purchase_amount => 0,
      p_max_discount_amount => 5000,
      p_is_active => true
    ) as r
  ) s \gset

-- Puntos para tres clientes.
select public.loyalty_purchase_register(
  p_business_id => :'biz'::uuid,
  p_customer_id => '70000000-0000-4000-8000-000000000004',
  p_amount_cop => 15000,
  p_eligible_amount_cop => 15000,
  p_idempotency_key => 'f6-compra-0001'
);
select public.loyalty_purchase_register(
  p_business_id => :'biz'::uuid,
  p_customer_id => '70000000-0000-4000-8000-000000000005',
  p_amount_cop => 15000,
  p_eligible_amount_cop => 15000,
  p_idempotency_key => 'f6-compra-0002'
);
select public.loyalty_purchase_register(
  p_business_id => :'biz'::uuid,
  p_customer_id => '70000000-0000-4000-8000-000000000006',
  p_amount_cop => 15000,
  p_eligible_amount_cop => 15000,
  p_idempotency_key => 'f6-compra-0003'
);

-- =====================================================================
-- 1. Solicitud del cliente (token de canje)
-- =====================================================================
select tests.as_user('70000000-0000-4000-8000-000000000004');
select r->>'redemption_id' as red1,
       r->>'token' as tok1,
       r->>'code' as code1
  from (
    select public.reward_request_redemption(
      :'biz'::uuid, :'reward_id'::uuid, 'f6-canje-0001'
    ) as r
  ) s \gset

select tests.assert_eq_text(
  (select origin from public.loyalty_redemptions where id = :'red1'::uuid),
  'manual',
  'la solicitud nace con origen manual'
);

-- =====================================================================
-- 2. Contexto del token (el negocio sale del token)
-- =====================================================================
select tests.as_user('70000000-0000-4000-8000-000000000001');
select tests.assert_eq_text(
  (public.redemption_token_context(:'tok1'))->>'business_id',
  :'biz',
  'el contexto resuelve el negocio desde el token'
);
select tests.assert_eq_text(
  (public.redemption_token_context(:'tok1'))->>'business_name',
  'Negocio F6',
  'el contexto devuelve el nombre del negocio'
);
select tests.assert_eq_text(
  (public.redemption_token_context(:'tok1'))->>'reward_name',
  'Postre F6',
  'el contexto devuelve la recompensa'
);
select tests.assert_eq_int(
  ((public.redemption_token_context(:'tok1'))->>'points_spent')::integer,
  10,
  'el contexto devuelve los loopoints'
);
select tests.assert(
  ((public.redemption_token_context(:'tok1'))->>'can_redeem')::boolean,
  'un token pendiente y vigente se puede canjear'
);
select tests.assert(
  coalesce((public.redemption_token_context(:'tok1'))->>'customer_nickname', '') <> '',
  'el contexto devuelve el nickname del cliente'
);
select tests.assert_eq_text(
  (public.redemption_token_context(:'tok1'))->>'role',
  'admin',
  'el contexto informa el rol del usuario en el negocio'
);
select tests.assert(
  not ((public.redemption_token_context(:'tok1')) ? 'token_hash'),
  'el contexto nunca devuelve el hash del token'
);

-- El encargado autorizado también puede resolverlo.
select tests.as_user('70000000-0000-4000-8000-000000000002');
select tests.assert_eq_text(
  (public.redemption_token_context(:'tok1'))->>'business_id',
  :'biz',
  'el encargado con permiso resuelve el token'
);

-- El encargado sin permiso no puede.
select tests.as_user('70000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.redemption_token_context(%L)$$, :'tok1'),
  'forbidden'
);

-- Un administrador ajeno tampoco.
select tests.as_user('70000000-0000-4000-8000-000000000007');
select tests.expect_error(
  format($$select public.redemption_token_context(%L)$$, :'tok1'),
  'business_not_found_or_no_access'
);

select tests.expect_error(
  $$select public.redemption_token_context('token-inventado-de-prueba-123456')$$,
  'invalid_token'
);
select tests.expect_error(
  $$select public.redemption_token_context('corto')$$,
  'invalid_token'
);

-- =====================================================================
-- 3. Confirmación de entrega con el token
-- =====================================================================
select tests.as_user('70000000-0000-4000-8000-000000000002');
select r->>'status' as red1_status
  from (select public.redemption_redeem_by_token(:'tok1') as r) s \gset

select tests.assert_eq_text(:'red1_status', 'delivered', 'el escaneo entrega la recompensa');
select tests.assert_eq_text(
  (select status::text from public.loyalty_redemptions where id = :'red1'::uuid),
  'delivered',
  'la redención queda entregada'
);
select tests.assert_eq_text(
  (select origin from public.loyalty_redemptions where id = :'red1'::uuid),
  'qr_scan',
  'la redención escaneada se marca con origen qr_scan'
);
select tests.assert(
  (select consumed_at is not null from public.loyalty_redemption_tokens
    where redemption_id = :'red1'::uuid),
  'el token queda consumido al entregar'
);
select tests.assert(
  exists (
    select 1 from public.business_audit_log_page(:'biz'::uuid, 'redemption.scanned', 50, 0)
  ),
  'el escaneo queda auditado'
);
select tests.assert(
  exists (
    select 1 from public.business_audit_log_page(:'biz'::uuid, 'redemption.delivered', 50, 0)
  ),
  'la entrega escaneada queda auditada'
);

-- El token ya no se puede reutilizar.
select tests.expect_error(
  format($$select public.redemption_redeem_by_token(%L)$$, :'tok1'),
  'redemption_already_delivered'
);
select tests.expect_error(
  format($$select public.redemption_redeem_by_token(%L)$$, :'tok1'),
  'redemption_already_delivered'
);

-- =====================================================================
-- 4. Token vencido
-- =====================================================================
select tests.as_user('70000000-0000-4000-8000-000000000005');
select r->>'redemption_id' as red2,
       r->>'token' as tok2
  from (
    select public.reward_request_redemption(
      :'biz'::uuid, :'reward_id'::uuid, 'f6-canje-0002'
    ) as r
  ) s \gset

reset role;
update public.loyalty_redemption_tokens
   set expires_at = now() - interval '1 minute'
 where redemption_id = :'red2'::uuid;
set local role authenticated;

select tests.as_user('70000000-0000-4000-8000-000000000001');
select tests.assert(
  not ((public.redemption_token_context(:'tok2'))->>'can_redeem')::boolean,
  'un token vencido no se puede canjear'
);
select tests.assert_eq_text(
  (public.redemption_token_context(:'tok2'))->>'reason',
  'token_expired',
  'el contexto explica que el token venció'
);
select tests.expect_error(
  format($$select public.redemption_redeem_by_token(%L)$$, :'tok2'),
  'token_expired'
);

-- =====================================================================
-- 5. Origen manual frente a escaneado en el listado
-- =====================================================================
select tests.as_user('70000000-0000-4000-8000-000000000006');
select r->>'redemption_id' as red3
  from (
    select public.reward_request_redemption(
      :'biz'::uuid, :'reward_id'::uuid, 'f6-canje-0003'
    ) as r
  ) s \gset

select tests.as_user('70000000-0000-4000-8000-000000000001');
select public.redemption_approve(:'biz'::uuid, :'red3'::uuid, true);

select tests.assert_eq_int(
  (select count(*) from public.loyalty_redemptions_list(
    :'biz'::uuid, null, 100, 0, 'qr_scan'
  )),
  1,
  'el filtro qr_scan devuelve solo la entrega escaneada'
);
select tests.assert_eq_int(
  (select count(*) from public.loyalty_redemptions_list(
    :'biz'::uuid, null, 100, 0, 'manual'
  )),
  2,
  'el filtro manual incluye la pendiente y la aprobada desde la lista'
);
select tests.assert_eq_text(
  (select origin from public.loyalty_redemptions_list(
    :'biz'::uuid, null, 100, 0, null
  ) where id = :'red1'::uuid),
  'qr_scan',
  'el listado incluye el origen escaneado'
);
select tests.assert(
  (select customer_nickname is not null from public.loyalty_redemptions_list(
    :'biz'::uuid, null, 100, 0, null
  ) where id = :'red1'::uuid),
  'el listado incluye el nickname del cliente'
);
select tests.expect_error(
  format(
    $$select * from public.loyalty_redemptions_list(%L::uuid, null, 100, 0, 'otro')$$,
    :'biz'
  ),
  'invalid_origin'
);

-- =====================================================================
-- 6. Aislamiento: otro negocio no ve estas solicitudes
-- =====================================================================
select tests.as_user('70000000-0000-4000-8000-000000000007');
select r->>'business_id' as biz2
  from (select public.business_register('Negocio Ajeno F6', 'negocio-ajeno-f6') as r) s \gset

select tests.expect_error(
  format(
    $$select * from public.loyalty_redemptions_list(%L::uuid, null, 100, 0, null)$$,
    :'biz'
  ),
  'business_not_found_or_no_access'
);
select tests.assert_eq_int(
  (select count(*) from public.loyalty_redemptions_list(
    :'biz2'::uuid, null, 100, 0, null
  )),
  0,
  'el negocio ajeno no ve solicitudes del negocio F6'
);

rollback;
