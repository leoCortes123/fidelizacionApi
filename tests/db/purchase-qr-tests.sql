-- =====================================================================
-- Pruebas del flujo de venta con QR por negocio
--   * el staff genera la venta y el QR (no asigna puntos a mano)
--   * la vista previa funciona sin sesión
--   * el cliente que escanea se afilia y recibe los puntos
--   * un QR solo se reclama una vez; cancelado o vencido no acredita
--   * el historial y la anulación quedan aislados por negocio
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('20000000-0000-4000-8000-000000000001', 'qr-admin@example.test', '{"full_name":"Admin QR"}'),
  ('20000000-0000-4000-8000-000000000002', 'qr-encargado@example.test', '{"full_name":"Encargado QR"}'),
  ('20000000-0000-4000-8000-000000000003', 'qr-cliente@example.test', '{"full_name":"Cliente QR"}'),
  ('20000000-0000-4000-8000-000000000004', 'qr-cliente2@example.test', '{"full_name":"Cliente QR Dos"}'),
  ('20000000-0000-4000-8000-000000000005', 'qr-ajeno@example.test', '{"full_name":"Admin Ajeno"}');

-- ---------------------------------------------------------------------
-- Negocio, encargado y programa activo
-- ---------------------------------------------------------------------
set local role authenticated;
select tests.as_user('20000000-0000-4000-8000-000000000001');

select r->>'business_id' as biz
  from (select public.business_register('Taquería QR', 'taqueria-qr') as r) s \gset

select tests.assert(:'biz' <> '', 'business_register devuelve el negocio');

select public.business_membership_create(
  :'biz'::uuid, '20000000-0000-4000-8000-000000000002', 'encargado', false
);

select public.loyalty_program_configure(
  p_business_id => :'biz'::uuid,
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

-- ---------------------------------------------------------------------
-- El encargado genera la venta de 15.500 COP
-- ---------------------------------------------------------------------
select tests.as_user('20000000-0000-4000-8000-000000000002');

select r->>'token' as token, r->>'purchase_id' as purchase1,
       (r->>'points_preview')::integer as preview
  from (select public.purchase_qr_create(:'biz'::uuid, 15500) as r) s \gset

select tests.assert(:'token' <> '', 'purchase_qr_create devuelve un token');
select tests.assert_eq_int(:preview, 15, 'la vista previa calcula 15 puntos');

reset role;
select tests.assert_eq_text(
  (select status::text from public.purchases where id = :'purchase1'::uuid),
  'pending_claim',
  'la venta nace pendiente de reclamo'
);
select tests.assert_eq_text(
  (select business_id::text from public.purchases where id = :'purchase1'::uuid),
  :'biz',
  'la venta queda asociada al negocio'
);

-- ---------------------------------------------------------------------
-- La vista previa no requiere sesión
-- ---------------------------------------------------------------------
set local role anon;
select tests.assert_eq_text(
  public.purchase_qr_preview(:'token')->>'business_name',
  'Taquería QR',
  'la vista previa muestra el negocio sin sesión'
);
select tests.assert_eq_int(
  (public.purchase_qr_preview(:'token')->>'amount_cop')::bigint,
  15500,
  'la vista previa muestra el importe'
);
select tests.assert_eq_int(
  (public.purchase_qr_preview(:'token')->>'points_preview')::bigint,
  15,
  'la vista previa muestra los puntos estimados'
);
select tests.assert_eq_text(
  public.purchase_qr_preview(:'token')->>'status',
  'pending_claim',
  'la vista previa indica que está pendiente'
);

select tests.expect_error(
  $sql$select public.purchase_qr_preview('token-invalido-de-menos-de-20')$sql$,
  'invalid_token'
);
select tests.expect_error(
  $sql$select public.purchase_qr_claim('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')$sql$,
  'permission denied'
);

-- ---------------------------------------------------------------------
-- El cliente escanea, se afilia y recibe los puntos
-- ---------------------------------------------------------------------
set local role authenticated;
select tests.as_user('20000000-0000-4000-8000-000000000003');

select public.purchase_qr_claim(:'token') as claim1 \gset

select tests.assert_eq_int(
  (:'claim1'::jsonb->>'points_awarded')::bigint,
  15,
  'el cliente recibe los 15 puntos'
);
select tests.assert_eq_int(
  (:'claim1'::jsonb->>'balance')::bigint,
  15,
  'el saldo del cliente queda en 15 puntos'
);
select tests.assert_eq_text(
  :'claim1'::jsonb->>'business_name',
  'Taquería QR',
  'el reclamo devuelve el negocio'
);

reset role;

select tests.assert_eq_int(
  (select count(*) from public.business_memberships
    where business_id = :'biz'::uuid
      and user_id = '20000000-0000-4000-8000-000000000003'),
  1,
  'escanear el QR afilia al cliente al negocio'
);
select tests.assert_eq_int(
  (select points_earned from public.loyalty_purchase_events
    where purchase_id = :'purchase1'::uuid),
  15,
  'se registra el evento de compra con los puntos'
);
select tests.assert_eq_int(
  (select count(*) from public.loyalty_purchase_events
    where purchase_id = :'purchase1'::uuid),
  1,
  'solo hay un evento por compra'
);
select tests.assert_eq_text(
  (select status::text from public.purchases where id = :'purchase1'::uuid),
  'claimed',
  'la compra queda marcada como reclamada'
);
select tests.assert_eq_int(
  (select points_awarded from public.purchases where id = :'purchase1'::uuid),
  15,
  'la compra guarda los puntos acreditados'
);
select tests.assert_eq_int(
  (select count(*) from public.business_audit_logs
    where business_id = :'biz'::uuid
      and operation = 'purchase.qr_claimed'
      and entity_id = :'purchase1'),
  1,
  'el reclamo queda en la auditoría del negocio'
);

set local role authenticated;
select tests.as_user('20000000-0000-4000-8000-000000000003');

select tests.expect_error(
  format('select public.purchase_qr_claim(%L)', :'token'),
  'purchase_already_claimed'
);

select tests.assert_eq_text(
  public.purchase_qr_preview(:'token')->>'status',
  'claimed',
  'la vista previa refleja que ya fue reclamada'
);

-- El QR de otro negocio no puede reclamarse por un ajeno sin el token.
select tests.assert_eq_int(
  (public.purchase_qr_preview(:'token')->>'amount_cop')::bigint,
  15500,
  'el token sigue mostrando la compra ya reclamada'
);

-- ---------------------------------------------------------------------
-- Compra cancelada: no acredita puntos
-- ---------------------------------------------------------------------
select tests.as_user('20000000-0000-4000-8000-000000000001');

select r->>'token' as token2, r->>'purchase_id' as purchase2
  from (select public.purchase_qr_create(:'biz'::uuid, 8000) as r) s \gset

select public.purchase_qr_cancel(:'biz'::uuid, :'purchase2'::uuid, 'Cobro duplicado');

select tests.as_user('20000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format('select public.purchase_qr_claim(%L)', :'token2'),
  'purchase_cancelled'
);

-- ---------------------------------------------------------------------
-- Compra vencida: no acredita puntos y pasa a expired
-- ---------------------------------------------------------------------
select tests.as_user('20000000-0000-4000-8000-000000000001');

select r->>'token' as token3, r->>'purchase_id' as purchase3
  from (select public.purchase_qr_create(:'biz'::uuid, 5000) as r) s \gset

reset role;
update public.purchases
   set created_at = now() - interval '2 hours',
       expires_at = now() - interval '1 hour'
 where id = :'purchase3'::uuid;
reset role;

set local role authenticated;
select tests.as_user('20000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format('select public.purchase_qr_claim(%L)', :'token3'),
  'purchase_expired'
);

reset role;
select tests.assert_eq_text(
  public.purchase_qr_preview(:'token3')->>'status',
  'expired',
  'el QR vencido se informa como expired'
);

-- ---------------------------------------------------------------------
-- Historial del negocio (con filtros y total)
-- ---------------------------------------------------------------------
set local role authenticated;
select tests.as_user('20000000-0000-4000-8000-000000000001');

select tests.assert_eq_int(
  (select total_count from public.business_purchases_list(:'biz'::uuid, 20, 0, null) limit 1),
  3,
  'el historial devuelve las tres ventas del negocio'
);
select tests.assert_eq_int(
  (select count(*) from public.business_purchases_list(:'biz'::uuid, 20, 0, 'claimed')),
  1,
  'el filtro por reclamadas devuelve una'
);
select tests.assert_eq_text(
  (select customer_name
     from public.business_purchases_list(:'biz'::uuid, 20, 0, 'claimed')),
  'Cliente QR',
  'el historial muestra el cliente que reclamó'
);

-- ---------------------------------------------------------------------
-- Aislamiento: otro negocio no ve ni anula estas ventas
-- ---------------------------------------------------------------------
select tests.as_user('20000000-0000-4000-8000-000000000005');

select r->>'business_id' as biz2
  from (select public.business_register('Otro Negocio QR', 'otro-negocio-qr') as r) s \gset

select tests.expect_error(
  format('select public.business_purchases_list(%L::uuid, 20, 0, null)', :'biz'),
  'business_not_found_or_no_access'
);
select tests.expect_error(
  format(
    'select public.purchase_qr_cancel(%L::uuid, %L::uuid, %L)',
    :'biz', :'purchase1', 'Intento ajeno'
  ),
  'business_not_found_or_no_access'
);
select tests.expect_error(
  format('select public.purchase_qr_create(%L::uuid, 10000)', :'biz'),
  'business_not_found_or_no_access'
);

select tests.assert_eq_int(
  (select count(*) from public.business_purchases_list(:'biz2'::uuid, 20, 0, null)),
  0,
  'el negocio ajeno no tiene ventas'
);

-- ---------------------------------------------------------------------
-- Programa inactivo: no se puede generar QR
-- ---------------------------------------------------------------------
select tests.as_user('20000000-0000-4000-8000-000000000001');
select public.loyalty_program_configure(
  p_business_id => :'biz'::uuid,
  p_cop_per_point_unit => 1000,
  p_points_per_cop_unit => 100,
  p_points_expiry_days => 365,
  p_budget_rate => 0.01,
  p_first_purchase_bonus_points => 0,
  p_recurrence_bonus_points => 0,
  p_referral_bonus_points => 0,
  p_qr_expiry_hours => 24,
  p_is_active => false
);
select tests.expect_error(
  format('select public.purchase_qr_create(%L::uuid, 10000)', :'biz'),
  'program_not_active'
);

rollback;
