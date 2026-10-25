-- =====================================================================
-- Pruebas de la Fase 0: roles por negocio, afiliación, acumulación,
-- redención con QR y aislamiento multiempresa.
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

-- Usuarios de prueba (el trigger crea perfiles y rol customer).
insert into auth.users (id, email, raw_user_meta_data) values
  ('10000000-0000-4000-8000-000000000001', 'dueno@example.test', '{"full_name":"Dueño Uno"}'),
  ('10000000-0000-4000-8000-000000000002', 'dueno2@example.test', '{"full_name":"Dueño Dos"}'),
  ('10000000-0000-4000-8000-000000000003', 'encargado@example.test', '{"full_name":"Encargado Uno"}'),
  ('10000000-0000-4000-8000-000000000004', 'cliente@example.test', '{"full_name":"Cliente Uno"}');

-- ---------------------------------------------------------------------
-- Registro de negocio y valores por defecto
-- ---------------------------------------------------------------------
set local role authenticated;
select tests.as_user('10000000-0000-4000-8000-000000000001');

select r->>'business_id' as biz1
  from (select public.business_register('Negocio Uno', 'negocio-uno') as r) s \gset

select tests.assert(:'biz1' <> '', 'business_register devuelve negocio');

select tests.assert_eq_int(
  (select count(*) from public.loyalty_programs where business_id = :'biz1'::uuid),
  1,
  'el registro crea el programa por defecto'
);
select tests.assert_eq_int(
  (select count(*) from public.business_economic_profiles where business_id = :'biz1'::uuid),
  1,
  'el registro crea el perfil económico'
);

select tests.assert_eq_text(
  (select role::text from public.businesses_list() where id = :'biz1'::uuid),
  'admin',
  'businesses_list devuelve el rol del usuario'
);

select tests.assert(
  'admin' = any (public.get_my_app_roles()),
  'get_my_app_roles incluye admin por membresía'
);

select tests.assert_eq_text(
  (public.loyalty_program_get(:'biz1'::uuid)).is_active::text,
  'false',
  'el programa nace inactivo'
);

select tests.assert_eq_int(
  (public.loyalty_program_get(:'biz1'::uuid)).cop_per_point_unit,
  1000,
  'el programa nace con 1 punto por 1000 COP'
);

-- Configuración explícita (primero borrador, luego activo).
select public.loyalty_program_configure(
  p_business_id => :'biz1'::uuid,
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
select tests.assert_eq_text(
  (public.loyalty_program_get(:'biz1'::uuid)).is_active::text,
  'false',
  'se puede guardar el programa sin activarlo'
);

select public.loyalty_program_configure(
  p_business_id => :'biz1'::uuid,
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
select tests.assert_eq_text(
  (public.loyalty_program_get(:'biz1'::uuid)).is_active::text,
  'true',
  'el administrador activa el programa'
);

-- Carta y recompensa.
select r->>'id' as product1
  from (
    select public.product_upsert(
      p_business_id => :'biz1'::uuid,
      p_price_cop => 12000,
      p_name => 'Taco de prueba',
      p_description => 'Producto de prueba',
      p_cost_cop => 5000,
      p_is_active => true
    ) as r
  ) s \gset

select r->>'id' as reward1
  from (
    select public.loyalty_reward_upsert(
      p_business_id => :'biz1'::uuid,
      p_type => 'free_product',
      p_name => 'Taco gratis',
      p_points_required => 10,
      p_product_id => :'product1'::uuid,
      p_description => 'Canje de prueba',
      p_is_active => true
    ) as r
  ) s \gset

select tests.assert(:'reward1' <> '', 'la recompensa se crea sobre la carta');

-- Regresión: products_list usaba columnas sin calificar y PostgreSQL fallaba
-- con «column reference "id" is ambiguous».
select tests.assert_eq_int(
  (select count(*) from public.products_list(:'biz1'::uuid, false)),
  1,
  'products_list devuelve la carta sin ambigüedad de columnas'
);
select tests.assert_eq_text(
  (select name from public.products_list(:'biz1'::uuid, false) limit 1),
  'Taco de prueba',
  'products_list devuelve el nombre del producto'
);

-- ---------------------------------------------------------------------
-- Afiliación de cliente y encargado
-- ---------------------------------------------------------------------
select tests.as_user('10000000-0000-4000-8000-000000000004');
select tests.assert_eq_text(
  (public.business_join('negocio-uno'))->>'role',
  'cliente',
  'el cliente se afilia por slug con rol cliente'
);
select tests.assert_eq_int(
  (select count(*) from public.loyalty_point_accounts
    where business_id = :'biz1'::uuid
      and customer_id = '10000000-0000-4000-8000-000000000004'),
  1,
  'la afiliación crea la cuenta de puntos'
);

select tests.as_user('10000000-0000-4000-8000-000000000001');
select public.business_membership_create(
  p_business_id => :'biz1'::uuid,
  p_user_id => '10000000-0000-4000-8000-000000000003',
  p_role => 'encargado',
  p_can_approve_redemptions => true
);
select tests.assert(
  exists (
    select 1 from public.business_memberships
     where business_id = :'biz1'::uuid
       and user_id = '10000000-0000-4000-8000-000000000003'
       and can_approve_redemptions
  ),
  'el admin crea encargado con permiso de aprobación'
);

select tests.assert(
  (select already_member from public.business_search_profiles(
     :'biz1'::uuid, 'cliente@example.test'
   )),
  'la búsqueda de perfiles marca al cliente ya afiliado'
);

-- Datos del negocio editables desde el wizard de configuración.
select public.business_update(
  p_business_id => :'biz1'::uuid,
  p_name => 'Negocio Uno',
  p_timezone => 'America/Bogota',
  p_operating_days => array[1, 2, 3, 4, 5]::smallint[]
);
select tests.assert_eq_text(
  (select timezone from public.businesses_list() where id = :'biz1'::uuid),
  'America/Bogota',
  'business_update guarda la zona horaria'
);
select tests.assert_eq_int(
  (select cardinality(operating_days) from public.businesses_list() where id = :'biz1'::uuid),
  5,
  'business_update guarda los días de operación'
);
select tests.expect_error(
  format(
    $$select public.business_update(%L::uuid, null, 'Marte/Olympus', null)$$,
    :'biz1'
  ),
  'invalid_timezone'
);

-- El admin no puede degradar al último administrador.
select tests.expect_error(
  format(
    $$select public.business_membership_create(%L::uuid, %L::uuid, 'encargado', false)$$,
    :'biz1', '10000000-0000-4000-8000-000000000001'
  ),
  'last_admin'
);

-- ---------------------------------------------------------------------
-- Acumulación de puntos y seguridad
-- ---------------------------------------------------------------------
select public.loyalty_purchase_register(
  p_business_id => :'biz1'::uuid,
  p_customer_id => '10000000-0000-4000-8000-000000000004',
  p_amount_cop => 15500,
  p_eligible_amount_cop => 15500,
  p_idempotency_key => 'fase0-compra-0001'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz1'::uuid, '10000000-0000-4000-8000-000000000004'
  ))->>'balance')::bigint,
  15,
  'la compra acumula floor(15500/1000)=15 puntos'
);

-- Reintento con la misma clave: no duplica.
select tests.assert(
  ((public.loyalty_purchase_register(
    p_business_id => :'biz1'::uuid,
    p_customer_id => '10000000-0000-4000-8000-000000000004',
    p_amount_cop => 15500,
    p_eligible_amount_cop => 15500,
    p_idempotency_key => 'fase0-compra-0001'
  ))->>'duplicate')::boolean,
  'la acumulación es idempotente por clave'
);

-- La compra queda registrada en la auditoría del negocio.
select tests.assert(
  exists (
    select 1 from public.business_audit_log_page(
      :'biz1'::uuid, 'purchase.registered', 50, 0
    )
  ),
  'la auditoría muestra la compra registrada'
);

-- ---------------------------------------------------------------------
-- Perfil económico y panel (Fase 4)
-- ---------------------------------------------------------------------
select public.business_economic_profile_upsert(
  p_business_id => :'biz1'::uuid,
  p_daily_avg_sales => 200000,
  p_monthly_operation_days => 26,
  p_daily_gain => 60000,
  p_gross_margin => 30,
  p_avg_customers_per_day => 40,
  p_max_monthly_reward_budget => 100000,
  p_data_status => '{"daily_avg_sales":"confirmed"}'::jsonb
);

select tests.assert_eq_int(
  ((public.business_economic_profile_get(:'biz1'::uuid))->>'daily_avg_sales')::integer,
  200000,
  'el perfil económico guarda las ventas diarias'
);
select tests.assert_eq_int(
  (public.business_dashboard_economic(:'biz1'::uuid)->>'monthly_estimated_sales_cop')::bigint,
  5200000,
  'el panel económico calcula ventas mensuales = 200000 × 26'
);
select tests.assert_eq_int(
  (public.business_dashboard_economic(:'biz1'::uuid)->>'max_monthly_reward_budget_cop')::integer,
  100000,
  'el panel económico respeta el presupuesto máximo configurado'
);

-- Un dato marcado como desconocido se limpia (semántica de formulario).
select public.business_economic_profile_upsert(
  p_business_id => :'biz1'::uuid,
  p_daily_avg_sales => null,
  p_monthly_operation_days => 26,
  p_daily_gain => null,
  p_gross_margin => null,
  p_avg_customers_per_day => null,
  p_max_monthly_reward_budget => 100000,
  p_data_status => '{"daily_avg_sales":"unknown"}'::jsonb
);
select tests.assert(
  (public.business_economic_profile_get(:'biz1'::uuid))->>'daily_avg_sales' is null,
  'marcar un dato como desconocido limpia su valor'
);

-- Compras que generan 0 puntos también son idempotentes (evento único).
select public.loyalty_purchase_register(
  p_business_id => :'biz1'::uuid,
  p_customer_id => '10000000-0000-4000-8000-000000000004',
  p_amount_cop => 500,
  p_eligible_amount_cop => 500,
  p_idempotency_key => 'fase4-compra-0000'
);
select tests.assert(
  ((public.loyalty_purchase_register(
    p_business_id => :'biz1'::uuid,
    p_customer_id => '10000000-0000-4000-8000-000000000004',
    p_amount_cop => 500,
    p_eligible_amount_cop => 500,
    p_idempotency_key => 'fase4-compra-0000'
  ))->>'duplicate')::boolean,
  'una compra de 0 puntos reintentada no duplica el evento'
);
select tests.assert_eq_int(
  (select count(*) from public.loyalty_purchase_events
    where business_id = :'biz1'::uuid
      and idempotency_key like '%fase4-compra-0000'),
  1,
  'solo existe un evento para la compra de 0 puntos'
);

-- Reverso de una compra registrada desde el panel.
select r->>'purchase_event_id' as purchase_event1
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'biz1'::uuid,
      p_customer_id => '10000000-0000-4000-8000-000000000004',
      p_amount_cop => 5000,
      p_eligible_amount_cop => 5000,
      p_idempotency_key => 'fase4-compra-0001'
    ) as r
  ) s \gset

select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz1'::uuid, '10000000-0000-4000-8000-000000000004'
  ))->>'balance')::bigint,
  20,
  'la compra de 5000 COP suma 5 puntos (15 + 5)'
);

select tests.assert_eq_int(
  ((public.loyalty_purchase_revert(
    p_business_id => :'biz1'::uuid,
    p_event_id => :'purchase_event1'::uuid,
    p_reason => 'Cobro duplicado en caja'
  ))->>'points_reversed')::integer,
  5,
  'el reverso devuelve los 5 puntos de la compra'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz1'::uuid, '10000000-0000-4000-8000-000000000004'
  ))->>'balance')::bigint,
  15,
  'el saldo vuelve a 15 tras el reverso'
);

-- El cliente no puede acreditarse puntos.
select tests.as_user('10000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format(
    $$select public.points_accrue_from_purchase(%L::uuid, gen_random_uuid(), null, 1000, 1000, 'hack-0001', %L::uuid)$$,
    :'biz1', '10000000-0000-4000-8000-000000000004'
  ),
  'forbidden'
);

-- El encargado no puede cambiar reglas ni crear miembros.
select tests.as_user('10000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.points_grant_bonus(%L::uuid, gen_random_uuid(), 'bonus', 10, 'x', 'bonus-0001', %L::uuid)$$,
         :'biz1', '10000000-0000-4000-8000-000000000003'),
  'forbidden'
);
select tests.expect_error(
  format($$select public.business_membership_create(%L::uuid, %L::uuid, 'cliente', false)$$,
         :'biz1', '10000000-0000-4000-8000-000000000004'),
  'forbidden'
);
select tests.expect_error(
  format($$select public.business_update(%L::uuid, 'Negocio hackeado', null, null)$$, :'biz1'),
  'forbidden'
);

-- ---------------------------------------------------------------------
-- Redención con QR, reemisión y entrega
-- ---------------------------------------------------------------------
select tests.as_user('10000000-0000-4000-8000-000000000004');

select r->>'redemption_id' as redemption1,
       r->>'token' as token1
  from (
    select public.reward_request_redemption(
      p_business_id => :'biz1'::uuid,
      p_reward_id => :'reward1'::uuid,
      p_idempotency_key => 'fase0-canje-0001'
    ) as r
  ) s \gset

select tests.assert(length(:'token1') >= 20, 'la solicitud devuelve token QR');
select tests.assert_eq_int(
  (select count(*) from public.loyalty_my_redemptions()),
  1,
  'el cliente ve su solicitud en loyalty_my_redemptions'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz1'::uuid, '10000000-0000-4000-8000-000000000004'
  ))->>'balance')::bigint,
  5,
  'la solicitud reserva 10 puntos'
);

-- Reemisión: el token anterior deja de ser válido.
select r->>'token' as token2
  from (select public.redemption_token_reissue(:'redemption1'::uuid) as r) s \gset

select tests.as_user('10000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format($$select public.redemption_token_validate(%L::uuid, %L)$$, :'biz1', :'token1'),
  'invalid_token'
);
select tests.assert_eq_text(
  (public.redemption_token_validate(:'biz1'::uuid, :'token2'))->>'customer_id',
  '10000000-0000-4000-8000-000000000004',
  'la validación devuelve el customer_id real'
);
select tests.assert_eq_text(
  (public.redemption_token_validate(:'biz1'::uuid, :'token2'))->>'status',
  'pending',
  'el QR reemitido está pendiente'
);

select public.redemption_approve(:'biz1'::uuid, :'redemption1'::uuid, true);
select public.redemption_deliver(:'biz1'::uuid, :'redemption1'::uuid);

select tests.assert_eq_text(
  (select status::text from public.loyalty_redemptions where id = :'redemption1'::uuid),
  'delivered',
  'la redención se entrega'
);

select tests.as_user('10000000-0000-4000-8000-000000000004');
select tests.assert_eq_text(
  (select status::text from public.loyalty_my_redemptions() where id = :'redemption1'::uuid),
  'delivered',
  'el cliente ve el estado delivered'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz1'::uuid, '10000000-0000-4000-8000-000000000004'
  ))->>'balance')::bigint,
  5,
  'la entrega consume los 10 puntos reservados'
);

-- ---------------------------------------------------------------------
-- Bono, cancelación de redención y reverso de compra (mismo libro)
-- ---------------------------------------------------------------------
select tests.as_user('10000000-0000-4000-8000-000000000001');

select public.points_grant_bonus(
  p_business_id => :'biz1'::uuid,
  p_account_id => (
    select id from public.loyalty_point_accounts
     where business_id = :'biz1'::uuid
       and customer_id = '10000000-0000-4000-8000-000000000004'
  ),
  p_bonus_type => 'manual',
  p_points => 10,
  p_reason => 'Bono de prueba',
  p_idempotency_key => 'fase0-bono-0001',
  p_created_by => '10000000-0000-4000-8000-000000000001'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz1'::uuid, '10000000-0000-4000-8000-000000000004'
  ))->>'balance')::bigint,
  15,
  'el bono acredita puntos sobre el saldo existente'
);

-- Segunda redención: se cancela y libera.
select tests.as_user('10000000-0000-4000-8000-000000000004');
select r->>'redemption_id' as redemption2
  from (
    select public.reward_request_redemption(
      p_business_id => :'biz1'::uuid,
      p_reward_id => :'reward1'::uuid,
      p_idempotency_key => 'fase0-canje-0002'
    ) as r
  ) s \gset

select tests.as_user('10000000-0000-4000-8000-000000000001');
select public.redemption_cancel(
  :'biz1'::uuid, :'redemption2'::uuid, 'Cancelada en prueba'
);
select tests.assert_eq_text(
  (select status::text from public.loyalty_redemptions where id = :'redemption2'::uuid),
  'cancelled',
  'el admin cancela una redención pendiente'
);
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz1'::uuid, '10000000-0000-4000-8000-000000000004'
  ))->>'balance')::bigint,
  15,
  'la cancelación libera los puntos reservados'
);

-- ---------------------------------------------------------------------
-- Aislamiento entre negocios
-- ---------------------------------------------------------------------
select tests.as_user('10000000-0000-4000-8000-000000000002');
select r->>'business_id' as biz2
  from (select public.business_register('Negocio Dos', 'negocio-dos') as r) s \gset

select tests.assert_eq_int(
  (select count(*) from public.businesses_list()),
  1,
  'cada admin solo ve sus negocios'
);
select tests.expect_error(
  format($$select public.loyalty_program_get(%L::uuid)$$, :'biz1'),
  'business_not_found_or_no_access'
);
select tests.expect_error(
  format($$select public.loyalty_rewards_list(%L::uuid, true)$$, :'biz1'),
  'business_not_found_or_no_access'
);

-- ---------------------------------------------------------------------
-- Roles de aplicación
-- ---------------------------------------------------------------------
select tests.as_user('10000000-0000-4000-8000-000000000003');
select tests.assert(
  'registrar' = any (public.get_my_app_roles()),
  'el encargado recibe el rol registrar en la app'
);

select tests.as_user('10000000-0000-4000-8000-000000000004');
select tests.assert(
  'customer' = any (public.get_my_app_roles()),
  'el cliente conserva el rol customer'
);

-- =====================================================================
-- Fase 6: vencimiento por lote, campañas y snapshots
-- =====================================================================
reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('10000000-0000-4000-8000-000000000006', 'cliente6@example.test', '{"full_name":"Cliente Seis"}');
set local role authenticated;

select tests.as_user('10000000-0000-4000-8000-000000000001');
select public.business_membership_create(
  p_business_id => :'biz1'::uuid,
  p_user_id => '10000000-0000-4000-8000-000000000006',
  p_role => 'cliente',
  p_can_approve_redemptions => false
);

-- ---------------------------------------------------------------------
-- Vencimiento FIFO: el lote más antiguo vence; el nuevo no se toca.
-- ---------------------------------------------------------------------
select r->>'points_earned' as p6_lot1_points
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'biz1'::uuid,
      p_customer_id => '10000000-0000-4000-8000-000000000006',
      p_amount_cop => 10000,
      p_eligible_amount_cop => 10000,
      p_idempotency_key => 'fase6-exp-0001'
    ) as r
  ) s \gset
select tests.assert_eq_int(:'p6_lot1_points'::integer, 10, 'el lote 1 acumula 10 puntos');

select r->>'points_earned' as p6_lot2_points
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'biz1'::uuid,
      p_customer_id => '10000000-0000-4000-8000-000000000006',
      p_amount_cop => 20000,
      p_eligible_amount_cop => 20000,
      p_idempotency_key => 'fase6-exp-0002'
    ) as r
  ) s \gset
select tests.assert_eq_int(:'p6_lot2_points'::integer, 20, 'el lote 2 acumula 20 puntos');

select id as p6_lot1_id
  from public.loyalty_point_transactions
 where business_id = :'biz1'::uuid
   and account_id = (
     select id from public.loyalty_point_accounts
      where business_id = :'biz1'::uuid
        and customer_id = '10000000-0000-4000-8000-000000000006'
   )
   and idempotency_key like '%fase6-exp-0001' \gset

-- Se simula que el primer lote ya venció (sin esperar 365 días).
reset role;
update public.loyalty_point_transactions
   set created_at = now() - interval '40 days',
       expires_at = now() - interval '1 day'
 where id = :'p6_lot1_id'::uuid;
set local role authenticated;

select tests.as_user('10000000-0000-4000-8000-000000000001');
select r->>'lots_expired' as p6_exp_lots,
       r->>'points_expired' as p6_exp_points
  from (select public.points_expire_due(:'biz1'::uuid) as r) s \gset
select tests.assert_eq_int(:'p6_exp_lots'::integer, 1, 'vence un único lote');
select tests.assert_eq_int(:'p6_exp_points'::integer, 10, 'vence solo el lote antiguo');
select tests.assert_eq_int(
  ((public.loyalty_account_balance(
    :'biz1'::uuid, '10000000-0000-4000-8000-000000000006'
  ))->>'balance')::bigint,
  20,
  'el lote nuevo conserva sus 20 puntos'
);

select tests.assert(
  coalesce((public.points_expire_due(:'biz1'::uuid)->>'points_expired')::integer, 0) = 0,
  'el vencimiento es idempotente al repetirse'
);
select tests.assert(
  exists (
    select 1 from public.business_audit_log_page(
      :'biz1'::uuid, 'points.expired', 50, 0
    )
  ),
  'el vencimiento queda auditado'
);
select tests.assert(
  exists (
    select 1 from public.loyalty_point_transactions
     where business_id = :'biz1'::uuid
       and movement_type = 'expiry_debit'
       and idempotency_key = 'expiry:' || :'p6_lot1_id'
  ),
  'el débito de vencimiento se vincula al lote'
);

-- ---------------------------------------------------------------------
-- Campañas: multiplicador/bono solo dentro de vigencia.
-- ---------------------------------------------------------------------
select r->>'id' as p6_camp1
  from (
    select public.loyalty_campaign_upsert(
      p_business_id => :'biz1'::uuid,
      p_name => 'Doble puntos',
      p_multiplier => 2,
      p_bonus_points => 0,
      p_min_purchase_amount => 0,
      p_valid_from => now() - interval '1 hour',
      p_valid_until => now() + interval '1 day',
      p_is_active => true,
      p_description => 'Prueba'
    ) as r
  ) s \gset

select r->>'points_earned' as p6_camp_points,
       r->>'base_points' as p6_camp_base,
       r->>'campaign_id' as p6_camp_applied
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'biz1'::uuid,
      p_customer_id => '10000000-0000-4000-8000-000000000006',
      p_amount_cop => 10000,
      p_eligible_amount_cop => 10000,
      p_idempotency_key => 'fase6-camp-0001'
    ) as r
  ) s \gset
select tests.assert_eq_int(:'p6_camp_base'::integer, 10, 'la campaña conserva los puntos base');
select tests.assert_eq_int(:'p6_camp_points'::integer, 20, 'la campaña duplica los puntos');
select tests.assert_eq_text(:'p6_camp_applied', :'p6_camp1', 'la respuesta identifica la campaña aplicada');

-- Se desactiva la campaña y se crea otra futura: ninguna debe aplicarse.
select public.loyalty_campaign_upsert(
  p_business_id => :'biz1'::uuid,
  p_name => 'Doble puntos',
  p_multiplier => 2,
  p_bonus_points => 0,
  p_min_purchase_amount => 0,
  p_valid_from => now() - interval '1 hour',
  p_valid_until => now() + interval '1 day',
  p_is_active => false,
  p_description => 'Prueba',
  p_id => :'p6_camp1'::uuid
);
select public.loyalty_campaign_upsert(
  p_business_id => :'biz1'::uuid,
  p_name => 'Campaña futura',
  p_multiplier => 5,
  p_bonus_points => 0,
  p_min_purchase_amount => 0,
  p_valid_from => now() + interval '1 day',
  p_valid_until => now() + interval '2 days',
  p_is_active => true
);

select r->>'points_earned' as p6_no_camp_points
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'biz1'::uuid,
      p_customer_id => '10000000-0000-4000-8000-000000000006',
      p_amount_cop => 10000,
      p_eligible_amount_cop => 10000,
      p_idempotency_key => 'fase6-camp-0002'
    ) as r
  ) s \gset
select tests.assert_eq_int(
  :'p6_no_camp_points'::integer,
  10,
  'una campaña inactiva o futura no se aplica'
);

-- Campaña de bono fijo.
select public.loyalty_campaign_upsert(
  p_business_id => :'biz1'::uuid,
  p_name => 'Bono de bienvenida',
  p_multiplier => 1,
  p_bonus_points => 5,
  p_min_purchase_amount => 5000,
  p_valid_from => now() - interval '1 hour',
  p_valid_until => now() + interval '1 day',
  p_is_active => true
);
select r->>'points_earned' as p6_bonus_points
  from (
    select public.loyalty_purchase_register(
      p_business_id => :'biz1'::uuid,
      p_customer_id => '10000000-0000-4000-8000-000000000006',
      p_amount_cop => 6000,
      p_eligible_amount_cop => 6000,
      p_idempotency_key => 'fase6-camp-0003'
    ) as r
  ) s \gset
select tests.assert_eq_int(
  :'p6_bonus_points'::integer,
  11,
  'la campaña de bono aplica si se cumple la compra mínima (6 puntos + 5)'
);

-- El encargado no puede gestionar campañas.
select tests.as_user('10000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format(
    $$select public.loyalty_campaign_upsert(%L::uuid, 'Campaña hackeada', 2)$$,
    :'biz1'
  ),
  'forbidden'
);

select tests.as_user('10000000-0000-4000-8000-000000000001');
select tests.assert(
  (select count(*) from public.loyalty_campaign_list(:'biz1'::uuid, false)) >= 3,
  'el admin lista las campañas del negocio'
);

-- ---------------------------------------------------------------------
-- Snapshot mensual de presupuesto (reproducible)
-- ---------------------------------------------------------------------
select public.business_economic_profile_upsert(
  p_business_id => :'biz1'::uuid,
  p_daily_avg_sales => 100000,
  p_monthly_operation_days => 30,
  p_daily_gain => null,
  p_gross_margin => null,
  p_avg_customers_per_day => null,
  p_max_monthly_reward_budget => 50000,
  p_data_status => '{"daily_avg_sales":"confirmed","monthly_operation_days":"confirmed"}'::jsonb
);

select r->>'id' as p6_snapshot1,
       r->>'period_start' as p6_snapshot_period,
       r->>'monthly_sales_cop' as p6_snapshot_sales,
       r->>'reference_budget_cop' as p6_snapshot_ref,
       r->>'max_budget_cop' as p6_snapshot_max
  from (
    select public.loyalty_budget_snapshot_create(
      :'biz1'::uuid, date_trunc('month', now())::date
    ) as r
  ) s \gset

select tests.assert_eq_int(:'p6_snapshot_sales'::bigint, 3000000, 'el snapshot calcula ventas mensuales');
select tests.assert_eq_int(:'p6_snapshot_ref'::bigint, 30000, 'el snapshot calcula el presupuesto de referencia');
select tests.assert_eq_int(:'p6_snapshot_max'::bigint, 50000, 'el snapshot respeta el presupuesto máximo');

select r->>'id' as p6_snapshot2
  from (
    select public.loyalty_budget_snapshot_create(
      :'biz1'::uuid, date_trunc('month', now())::date
    ) as r
  ) s \gset
select tests.assert_eq_text(:'p6_snapshot2', :'p6_snapshot1', 'repetir el snapshot actualiza la misma fila');
select tests.assert_eq_int(
  (select count(*) from public.loyalty_budget_snapshots
    where business_id = :'biz1'::uuid
      and period_start = :'p6_snapshot_period'::date),
  1,
  'solo existe un snapshot por mes'
);
select tests.assert(
  (select count(*) from public.loyalty_budget_snapshot_list(:'biz1'::uuid, 12, 0)) >= 1,
  'el listado de snapshots devuelve el mes guardado'
);

select tests.as_user('10000000-0000-4000-8000-000000000003');
select tests.expect_error(
  format(
    $$select public.loyalty_budget_snapshot_create(%L::uuid, current_date)$$,
    :'biz1'
  ),
  'forbidden'
);
select tests.expect_error(
  $$select public.points_expire_all_due()$$,
  'permission denied'
);

-- El posteo interno no debe ser ejecutable por un cliente.
select tests.as_user('10000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format(
    $$select public.loyalty_transaction_post(
        %L::uuid,
        (select id from public.loyalty_point_accounts
          where business_id = %L::uuid
            and customer_id = %L::uuid),
        'admin_adjustment'::public.point_movement_type,
        999,
        'hack'::text, null::uuid, 'intento'::text, 'hack-fase6-0001'::text, %L::uuid
      )$$,
    :'biz1', :'biz1', '10000000-0000-4000-8000-000000000004',
    '10000000-0000-4000-8000-000000000004'
  ),
  'permission denied'
);

select tests.assert_eq_int(
  (select count(*) from pg_proc
    where proname = 'loyalty_transaction_post'
      and pronamespace = 'public'::regnamespace),
  1,
  'solo queda una firma vigente de loyalty_transaction_post'
);

rollback;

\echo '== Pruebas de Fase 0 completadas =='
