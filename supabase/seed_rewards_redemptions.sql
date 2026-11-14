-- =====================================================================
-- Seed: Recompensas, Cuentas de Puntos, Transacciones y Redenciones
-- =====================================================================

BEGIN;

-- 1. Insertar Recompensas para negocios que no las tienen o que necesitan más
-- Mis tacos (6683da46-8fa3-4f8b-944e-d9e7597dda5e)
INSERT INTO public.loyalty_rewards (
  id, business_id, product_id, type, name, description, points_required,
  min_purchase_amount, max_discount_amount, discount_percentage, product_price_cop, product_cost_cop,
  is_active, created_at, updated_at
) VALUES
  (
    '66830001-0000-4000-8000-000000000001',
    '6683da46-8fa3-4f8b-944e-d9e7597dda5e',
    'a8f3b8b4-f5ff-4ea8-9dd9-300bf7287de2',
    'free_product',
    'Agua Fresca de Horchata Gratis',
    'Agua fresca artesanal de horchata tradicional 500ml',
    25, 0, NULL, NULL, 7000, 2500, true, now(), now()
  ),
  (
    '66830001-0000-4000-8000-000000000002',
    '6683da46-8fa3-4f8b-944e-d9e7597dda5e',
    'd498b8bc-33c5-477e-b05f-fa9029543aae',
    'free_product',
    'Guacamole Artesanal con Totopos Gratis',
    'Guacamole recién preparado con totopos crocantes de maíz',
    45, 0, NULL, NULL, 15000, 6000, true, now(), now()
  ),
  (
    '66830001-0000-4000-8000-000000000003',
    '6683da46-8fa3-4f8b-944e-d9e7597dda5e',
    '2eb34c5f-39eb-4b59-b304-3059359cbc08',
    'free_product',
    'Orden x3 Tacos al Pastor Gratis',
    'Tres tacos al pastor marinados al trompo con piña y cilantro',
    70, 0, NULL, NULL, 24000, 10000, true, now(), now()
  ),
  (
    '66830001-0000-4000-8000-000000000004',
    '6683da46-8fa3-4f8b-944e-d9e7597dda5e',
    NULL,
    'percentage_discount',
    '15% Descuento en tu Cuenta Taquera',
    'Aplica en compras mayores a $30.000 COP (máximo $15.000)',
    50, 30000, 15000, 15.0, NULL, NULL, true, now(), now()
  )
ON CONFLICT (id) DO NOTHING;

-- Comidas rapidas (2cc6d587-5ae0-4a15-9322-444ea0c62281)
INSERT INTO public.loyalty_rewards (
  id, business_id, product_id, type, name, description, points_required,
  min_purchase_amount, max_discount_amount, discount_percentage, product_price_cop, product_cost_cop,
  is_active, created_at, updated_at
) VALUES
  (
    '2cc60001-0000-4000-8000-000000000001',
    '2cc6d587-5ae0-4a15-9322-444ea0c62281',
    'b5746b00-745a-4173-b111-afd9006ba47f',
    'free_product',
    'Gaseosa Postobón 400ml Gratis',
    'Gaseosa Manzana o Colombiana personal',
    15, 0, NULL, NULL, 4500, 2000, true, now(), now()
  ),
  (
    '2cc60001-0000-4000-8000-000000000002',
    '2cc6d587-5ae0-4a15-9322-444ea0c62281',
    '462e9b7e-660f-4c7c-9f31-aaa824f069e7',
    'free_product',
    'Papas Francesas Grandes con Cheddar Gratis',
    'Porción grande de papas a la francesa con abundante queso cheddar',
    35, 0, NULL, NULL, 11000, 4500, true, now(), now()
  ),
  (
    '2cc60001-0000-4000-8000-000000000003',
    '2cc6d587-5ae0-4a15-9322-444ea0c62281',
    '68f52e94-8844-4e7e-98bf-00f530dccdcb',
    'free_product',
    'Perro Caliente Americano Gratis',
    'Perro caliente americano con salchicha seleccionada, tocineta y salsas',
    50, 0, NULL, NULL, 15000, 6000, true, now(), now()
  ),
  (
    '2cc60001-0000-4000-8000-000000000004',
    '2cc6d587-5ae0-4a15-9322-444ea0c62281',
    NULL,
    'fixed_discount',
    'Bono Descuento $10.000 COP',
    'Descuento directo de $10.000 COP en pedidos superiores a $25.000',
    35, 25000, 10000, NULL, 10000, NULL, true, now(), now()
  )
ON CONFLICT (id) DO NOTHING;

-- Comidas rapidas2 (270776d7-b7ec-46d6-97e6-99f73ac5580a)
INSERT INTO public.loyalty_rewards (
  id, business_id, product_id, type, name, description, points_required,
  min_purchase_amount, max_discount_amount, discount_percentage, product_price_cop, product_cost_cop,
  is_active, created_at, updated_at
) VALUES
  (
    '27070001-0000-4000-8000-000000000001',
    '270776d7-b7ec-46d6-97e6-99f73ac5580a',
    '990b8108-0144-4ee1-9822-be125e3f8b1f',
    'free_product',
    'Jugo Hit en Botella Gratis',
    'Jugo Hit sabores surtidos 500ml',
    15, 0, NULL, NULL, 4500, 2000, true, now(), now()
  ),
  (
    '27070001-0000-4000-8000-000000000002',
    '270776d7-b7ec-46d6-97e6-99f73ac5580a',
    '856127b7-4604-4b81-bbe1-6c88424336a9',
    'free_product',
    'Aros de Cebolla Crocantes Gratis',
    'Aros apanados crocantes con dip especial',
    30, 0, NULL, NULL, 9000, 3800, true, now(), now()
  ),
  (
    '27070001-0000-4000-8000-000000000003',
    '270776d7-b7ec-46d6-97e6-99f73ac5580a',
    'e3df075a-40e7-4f67-8214-c8d3a77d31e4',
    'free_product',
    'Hamburguesa Sencilla de Carne Gratis',
    'Hamburguesa con carne a la parrilla, queso y vegetales frescos',
    35, 0, NULL, NULL, 10000, 8000, true, now(), now()
  ),
  (
    '27070001-0000-4000-8000-000000000004',
    '270776d7-b7ec-46d6-97e6-99f73ac5580a',
    '4e1d0369-b287-403f-a00f-9e5cc5306b58',
    'free_product',
    'Salchipapa Criolla Especial Gratis',
    'Papas criollas, salchicha manguera, tocineta y huevos de codorniz',
    55, 0, NULL, NULL, 19000, 8000, true, now(), now()
  )
ON CONFLICT (id) DO NOTHING;

-- empanadas (eb7ba0b9-aaae-40cf-a4c6-545c1fe31586)
INSERT INTO public.loyalty_rewards (
  id, business_id, product_id, type, name, description, points_required,
  min_purchase_amount, max_discount_amount, discount_percentage, product_price_cop, product_cost_cop,
  is_active, created_at, updated_at
) VALUES
  (
    'eb7b0001-0000-4000-8000-000000000001',
    'eb7ba0b9-aaae-40cf-a4c6-545c1fe31586',
    '665ff200-9486-4828-85e3-18d9ec22a523',
    'free_product',
    'Gaseosa Personal Gratis',
    'Gaseosa personal 250ml bien helada',
    15, 0, NULL, NULL, 1500, 1000, true, now(), now()
  ),
  (
    'eb7b0001-0000-4000-8000-000000000002',
    'eb7ba0b9-aaae-40cf-a4c6-545c1fe31586',
    '1e088bd4-1d1b-4c6c-af69-f6b091822d4d',
    'free_product',
    'Avena Helada Casera 300ml Gratis',
    'Vaso de avena helada casera con canela',
    20, 0, NULL, NULL, 4000, 1500, true, now(), now()
  )
ON CONFLICT (id) DO NOTHING;

-- 2. Asegurar que cada cliente afiliado tenga su cuenta de puntos
INSERT INTO public.loyalty_point_accounts (id, business_id, customer_id, balance, created_at, updated_at)
SELECT gen_random_uuid(), m.business_id, m.user_id, 0, now(), now()
FROM public.business_memberships m
WHERE m.role = 'cliente'
ON CONFLICT (business_id, customer_id) DO NOTHING;

-- 3. Acreditar compras y puntos para clientes en todas las cuentas
DO $$
DECLARE
  rec RECORD;
  v_pts INT;
  v_amt INT;
  v_ev_id UUID;
BEGIN
  FOR rec IN (
    SELECT a.id as account_id, a.business_id, a.customer_id, p.email
    FROM public.loyalty_point_accounts a
    JOIN public.profiles p ON p.id = a.customer_id
  ) LOOP
    v_pts := CASE 
      WHEN rec.email LIKE '%maria%' THEN 320
      WHEN rec.email LIKE '%juan%' THEN 300
      WHEN rec.email LIKE '%cortex%' THEN 280
      WHEN rec.email LIKE '%cliente001@%' THEN 250
      WHEN rec.email LIKE '%cliente002@%' THEN 240
      ELSE 200
    END;
    v_amt := v_pts * 1000;
    v_ev_id := gen_random_uuid();

    INSERT INTO public.loyalty_purchase_events (
      id, business_id, account_id, purchase_id, amount_cop, eligible_amount_cop,
      points_earned, rule_version, created_at, idempotency_key
    ) VALUES (
      v_ev_id, rec.business_id, rec.account_id, NULL, v_amt, v_amt,
      v_pts, '1.0', now() - interval '2 days', 'seed:event:boost:' || rec.account_id::text
    ) ON CONFLICT DO NOTHING;

    INSERT INTO public.loyalty_point_transactions (
      id, business_id, account_id, movement_type, points, reference_type,
      reference_id, reason, idempotency_key, created_by, created_at
    ) VALUES (
      gen_random_uuid(), rec.business_id, rec.account_id, 'purchase_credit',
      v_pts, 'purchase', v_ev_id, 'Compra acumulada en tienda',
      'seed:tx:boost:' || rec.account_id::text, rec.customer_id, now() - interval '2 days'
    ) ON CONFLICT (idempotency_key) DO NOTHING;

    UPDATE public.loyalty_point_accounts
    SET balance = (
      SELECT coalesce(sum(points), 0)
      FROM public.loyalty_point_transactions
      WHERE account_id = rec.account_id
    ), updated_at = now()
    WHERE id = rec.account_id;
  END LOOP;
END $$;

-- 4. Función temporal para registrar redenciones limpiamente
CREATE OR REPLACE FUNCTION pg_temp.add_test_redemption(
  p_redemption_id UUID,
  p_biz_id UUID,
  p_customer_id UUID,
  p_reward_id UUID,
  p_status redemption_request_status,
  p_code TEXT,
  p_idemp TEXT,
  p_created_interval INTERVAL,
  p_approved_by UUID DEFAULT NULL,
  p_approved_interval INTERVAL DEFAULT NULL,
  p_delivered_interval INTERVAL DEFAULT NULL,
  p_cancelled_interval INTERVAL DEFAULT NULL,
  p_cancellation_reason TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_acc_id UUID;
  v_rw public.loyalty_rewards;
  v_token_hash TEXT;
  v_created_at TIMESTAMPTZ := now() - p_created_interval;
  v_approved_at TIMESTAMPTZ := CASE WHEN p_approved_interval IS NOT NULL THEN now() - p_approved_interval ELSE NULL END;
  v_delivered_at TIMESTAMPTZ := CASE WHEN p_delivered_interval IS NOT NULL THEN now() - p_delivered_interval ELSE NULL END;
  v_cancelled_at TIMESTAMPTZ := CASE WHEN p_cancelled_interval IS NOT NULL THEN now() - p_cancelled_interval ELSE NULL END;
BEGIN
  SELECT id INTO v_acc_id
  FROM public.loyalty_point_accounts
  WHERE business_id = p_biz_id AND customer_id = p_customer_id;

  IF v_acc_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_rw
  FROM public.loyalty_rewards
  WHERE id = p_reward_id;

  IF v_rw.id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.loyalty_redemptions (
    id, business_id, account_id, reward_id, reward_name, reward_type,
    points_spent, code, status, idempotency_key, created_by, created_at,
    approved_by, approved_at, delivered_at, cancelled_at, cancellation_reason, origin
  ) VALUES (
    p_redemption_id, p_biz_id, v_acc_id, v_rw.id, v_rw.name, v_rw.type,
    v_rw.points_required, p_code, p_status, p_idemp, p_customer_id, v_created_at,
    p_approved_by, v_approved_at, v_delivered_at, v_cancelled_at, p_cancellation_reason, 'manual'
  ) ON CONFLICT (idempotency_key) DO NOTHING;

  v_token_hash := encode(extensions.digest('token:' || p_code, 'sha256'), 'hex');

  INSERT INTO public.loyalty_redemption_tokens (
    id, business_id, redemption_id, token_hash, expires_at, consumed_at, consumed_by, created_at
  ) VALUES (
    gen_random_uuid(), p_biz_id, p_redemption_id, v_token_hash,
    CASE WHEN p_status = 'pending' THEN now() + interval '24 hours' ELSE v_created_at + interval '24 hours' END,
    CASE WHEN p_status IN ('approved', 'delivered') THEN coalesce(v_approved_at, v_created_at) ELSE NULL END,
    CASE WHEN p_status IN ('approved', 'delivered') THEN coalesce(p_approved_by, p_customer_id) ELSE NULL END,
    v_created_at
  ) ON CONFLICT DO NOTHING;

  INSERT INTO public.loyalty_point_transactions (
    id, business_id, account_id, movement_type, points, reference_type,
    reference_id, reason, idempotency_key, created_by, created_at
  ) VALUES (
    gen_random_uuid(), p_biz_id, v_acc_id, 'redemption_debit',
    -v_rw.points_required, 'redemption', p_redemption_id,
    'Canje de recompensa: ' || v_rw.name,
    'seed:tx:debit:' || p_redemption_id::text, p_customer_id, v_created_at
  ) ON CONFLICT (idempotency_key) DO NOTHING;

  IF p_status = 'cancelled' THEN
    INSERT INTO public.loyalty_point_transactions (
      id, business_id, account_id, movement_type, points, reference_type,
      reference_id, reason, idempotency_key, created_by, created_at
    ) VALUES (
      gen_random_uuid(), p_biz_id, v_acc_id, 'redemption_refund',
      v_rw.points_required, 'redemption', p_redemption_id,
      'Reembolso por rechazo de solicitud: ' || v_rw.name,
      'seed:tx:refund:' || p_redemption_id::text, p_approved_by, v_cancelled_at
    ) ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;

  UPDATE public.loyalty_point_accounts
  SET balance = (
    SELECT coalesce(sum(points), 0)
    FROM public.loyalty_point_transactions
    WHERE account_id = v_acc_id
  ), updated_at = now()
  WHERE id = v_acc_id;
END;
$$;

-- Ejecutar las inserciones de redenciones
DO $$
DECLARE
  v_biz_emp UUID := 'eb7ba0b9-aaae-40cf-a4c6-545c1fe31586';
  v_biz_tac UUID := '6683da46-8fa3-4f8b-944e-d9e7597dda5e';
  v_biz_rap UUID := '2cc6d587-5ae0-4a15-9322-444ea0c62281';
  v_biz_rp2 UUID := '270776d7-b7ec-46d6-97e6-99f73ac5580a';
  v_biz_son UUID := '33333333-3333-4333-8333-333333333333';
  v_biz_aur UUID := '11111111-1111-4111-8111-111111111111';
  v_biz_nap UUID := '22222222-2222-4222-8222-222222222222';

  v_usr_maria UUID := 'd0000000-0000-4000-8000-000000000001';
  v_usr_juan UUID := 'd0000000-0000-4000-8000-000000000002';
  v_usr_cortex UUID := 'ff010f01-810c-400d-9a3d-77059b1c931c';
  v_usr_c1loop UUID := '5602945e-d362-46a5-85fa-a9a94e449bf7';
  v_usr_c2loop UUID := 'eb9cff7c-2a37-406c-aa95-ee1a91d1b107';
  v_usr_c1gml UUID := '6e9eb599-d9a9-4b3d-ab7f-489c42ec360f';
  v_usr_c2gml UUID := 'eea8832a-ab33-47c6-b823-613e50f31b3b';
  v_usr_c12gml UUID := '06c9181f-6377-4939-afd8-39c29cbc3573';
  v_usr_c1cli UUID := 'ecf00772-055f-459e-aebe-9785fa243568';

  v_enc_emp UUID := '753eaabb-bdbc-4ed7-b002-cbd5ae4b02f0';
  v_enc_tac UUID := '530cca8c-2633-4192-b905-a8c032c0d1e3';
  v_enc_son UUID := 'c0000000-0000-4000-8000-000000000002';
  v_enc_aur UUID := 'a0000000-0000-4000-8000-000000000002';
  v_enc_nap UUID := 'b0000000-0000-4000-8000-000000000002';
BEGIN
  -- SOLICITUDES PENDIENTES (pending)
  PERFORM pg_temp.add_test_redemption('e0000001-0001-4000-8000-000000000001', v_biz_emp, v_usr_cortex, '475e5b15-e86b-4cfe-a58e-7cb77dadfeec', 'pending', 'TPEMP01', 'seed:redemp:emp:01', interval '25 minutes');
  PERFORM pg_temp.add_test_redemption('e0000001-0001-4000-8000-000000000002', v_biz_emp, v_usr_c1loop, 'eb7b0001-0000-4000-8000-000000000002', 'pending', 'TPEMP02', 'seed:redemp:emp:02', interval '10 minutes');

  PERFORM pg_temp.add_test_redemption('e0000002-0001-4000-8000-000000000001', v_biz_tac, v_usr_juan, '66830001-0000-4000-8000-000000000003', 'pending', 'TPTAC01', 'seed:redemp:tac:01', interval '40 minutes');
  PERFORM pg_temp.add_test_redemption('e0000002-0001-4000-8000-000000000002', v_biz_tac, v_usr_c1gml, '66830001-0000-4000-8000-000000000002', 'pending', 'TPTAC02', 'seed:redemp:tac:02', interval '15 minutes');

  PERFORM pg_temp.add_test_redemption('e0000003-0001-4000-8000-000000000001', v_biz_son, v_usr_maria, '357eeb67-bcc1-4d4e-9f1b-ceeed73f81a2', 'pending', 'TPSON01', 'seed:redemp:son:01', interval '35 minutes');
  PERFORM pg_temp.add_test_redemption('e0000003-0001-4000-8000-000000000002', v_biz_son, v_usr_c1cli, 'c3b840c4-146d-4789-8db1-db2deea7885f', 'pending', 'TPSON02', 'seed:redemp:son:02', interval '8 minutes');

  PERFORM pg_temp.add_test_redemption('e0000004-0001-4000-8000-000000000001', v_biz_aur, v_usr_maria, '8a7ce458-b3a9-4d0e-bf77-ac9b50bd5283', 'pending', 'TPAUR01', 'seed:redemp:aur:01', interval '18 minutes');
  PERFORM pg_temp.add_test_redemption('e0000004-0001-4000-8000-000000000002', v_biz_aur, v_usr_cortex, '66353fc5-b27e-4fa5-97b0-1f37aa5acd15', 'pending', 'TPAUR02', 'seed:redemp:aur:02', interval '5 minutes');

  PERFORM pg_temp.add_test_redemption('e0000005-0001-4000-8000-000000000001', v_biz_nap, v_usr_juan, '66a2358d-bbac-4749-a011-9531723102ff', 'pending', 'TPNAP01', 'seed:redemp:nap:01', interval '50 minutes');
  PERFORM pg_temp.add_test_redemption('e0000005-0001-4000-8000-000000000002', v_biz_nap, v_usr_c12gml, 'a130f873-26e5-4966-9b2f-7a928cb4714b', 'pending', 'TPNAP02', 'seed:redemp:nap:02', interval '12 minutes');

  PERFORM pg_temp.add_test_redemption('e0000006-0001-4000-8000-000000000001', v_biz_rap, v_usr_maria, '2cc60001-0000-4000-8000-000000000002', 'pending', 'TPRAP01', 'seed:redemp:rap:01', interval '22 minutes');
  PERFORM pg_temp.add_test_redemption('e0000007-0001-4000-8000-000000000001', v_biz_rp2, v_usr_c2gml, '27070001-0000-4000-8000-000000000004', 'pending', 'TPRP201', 'seed:redemp:rp2:01', interval '14 minutes');

  -- SOLICITUDES APROBADAS (approved)
  PERFORM pg_temp.add_test_redemption('e0000001-0002-4000-8000-000000000001', v_biz_emp, v_usr_c2loop, 'b885f490-8491-4877-9be4-075eb9ee7b52', 'approved', 'TPEMPAP1', 'seed:redemp:emp:ap1', interval '2 hours', v_enc_emp, interval '1 hour');
  PERFORM pg_temp.add_test_redemption('e0000002-0002-4000-8000-000000000001', v_biz_tac, v_usr_c2loop, '66830001-0000-4000-8000-000000000001', 'approved', 'TPTACAP1', 'seed:redemp:tac:ap1', interval '3 hours', v_enc_tac, interval '2 hours');
  PERFORM pg_temp.add_test_redemption('e0000003-0002-4000-8000-000000000001', v_biz_son, v_usr_juan, '97a6fe68-0145-4609-af81-99d4f85e115a', 'approved', 'TPSONAP1', 'seed:redemp:son:ap1', interval '1 hour 30 minutes', v_enc_son, interval '45 minutes');
  PERFORM pg_temp.add_test_redemption('e0000004-0002-4000-8000-000000000001', v_biz_aur, v_usr_c1loop, 'c7637f4a-93cb-4041-b403-4c8bd6eb3953', 'approved', 'TPAURAP1', 'seed:redemp:aur:ap1', interval '2 hours', v_enc_aur, interval '30 minutes');
  PERFORM pg_temp.add_test_redemption('e0000005-0002-4000-8000-000000000001', v_biz_nap, v_usr_c2gml, 'a130f873-26e5-4966-9b2f-7a928cb4714b', 'approved', 'TPNAPAP1', 'seed:redemp:nap:ap1', interval '2 hours', v_enc_nap, interval '1 hour');
  PERFORM pg_temp.add_test_redemption('e0000006-0002-4000-8000-000000000001', v_biz_rap, v_usr_c12gml, '2cc60001-0000-4000-8000-000000000003', 'approved', 'TPRAPAP1', 'seed:redemp:rap:ap1', interval '2 hours', 'ed635c83-5f8f-4d88-b741-064f8c828565', interval '40 minutes');

  -- SOLICITUDES ENTREGADAS (delivered)
  PERFORM pg_temp.add_test_redemption('e0000003-0003-4000-8000-000000000001', v_biz_son, v_usr_maria, 'ced50a3e-166b-4fe1-94bf-de9e873dbb80', 'delivered', 'TPSONDEL1', 'seed:redemp:son:del1', interval '1 day', v_enc_son, interval '23 hours', interval '22 hours');
  PERFORM pg_temp.add_test_redemption('e0000005-0003-4000-8000-000000000001', v_biz_nap, v_usr_juan, '14eef32e-8808-44c4-989d-5f6f5b749a38', 'delivered', 'TPNAPDEL1', 'seed:redemp:nap:del1', interval '2 days', v_enc_nap, interval '1 day 23 hours', interval '1 day 22 hours');
  PERFORM pg_temp.add_test_redemption('e0000004-0003-4000-8000-000000000001', v_biz_aur, v_usr_maria, '8a7ce458-b3a9-4d0e-bf77-ac9b50bd5283', 'delivered', 'TPAURDEL1', 'seed:redemp:aur:del1', interval '3 days', v_enc_aur, interval '2 days 23 hours', interval '2 days 22 hours');

  -- SOLICITUDES CANCELADAS (cancelled)
  PERFORM pg_temp.add_test_redemption('e0000002-0004-4000-8000-000000000001', v_biz_tac, v_usr_cortex, '66830001-0000-4000-8000-000000000001', 'cancelled', 'TPTACCAN1', 'seed:redemp:tac:can1', interval '4 days', v_enc_tac, NULL, NULL, interval '3 days 23 hours', 'Rechazado por el encargado: Agotado en barra de bebidas');
END $$;

COMMIT;
