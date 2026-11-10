-- =====================================================================
-- DATOS DE PRUEBA Y DEMOSTRACIÓN LOOPOINT:
-- 3 NEGOCIOS, 2 ENCARGADOS POR NEGOCIO, CARTAS Y PROGRAMAS DE LEALTAD
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. LIMPIEZA DE DATOS ANTERIORES
-- ---------------------------------------------------------------------

alter table if exists public.points_ledger disable trigger points_ledger_immutable;
truncate table public.points_ledger cascade;
alter table if exists public.points_ledger enable trigger points_ledger_immutable;

truncate table public.purchase_items cascade;
truncate table public.purchases cascade;
truncate table public.redemptions cascade;
truncate table public.audit_log cascade;
truncate table public.config_history cascade;

truncate table public.businesses cascade;

delete from auth.identities
where user_id not in ('1db7e5c4-9018-4dee-bc99-f6376edf1936', 'b9cf226a-be74-433b-95bf-97006236a637');

delete from auth.users
where id not in ('1db7e5c4-9018-4dee-bc99-f6376edf1936', 'b9cf226a-be74-433b-95bf-97006236a637');

-- ---------------------------------------------------------------------
-- 2. CREACIÓN DE USUARIOS (ADMINISTRADORES, ENCARGADOS Y CLIENTES)
--    Contraseña común para pruebas: Loopoint2026!
-- ---------------------------------------------------------------------

insert into auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  confirmation_token,
  recovery_token,
  email_change_token_new,
  email_change,
  email_change_token_current,
  email_change_confirm_status,
  phone_change,
  phone_change_token,
  reauthentication_token,
  is_sso_user,
  is_anonymous,
  created_at,
  updated_at
) values
  -- Negocio 1: Café La Aurora
  ('a0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin@laaurora.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Santiago Mendoza - Admin La Aurora","email":"admin@laaurora.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),
  ('a0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'encargado1@laaurora.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Carlos Gómez - Encargado La Aurora","email":"encargado1@laaurora.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),
  ('a0000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'encargado2@laaurora.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Valentina Ruiz - Encargada La Aurora","email":"encargado2@laaurora.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),

  -- Negocio 2: Pizzería Napoli
  ('b0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin@napoli.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Marco Rossi - Admin Napoli","email":"admin@napoli.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),
  ('b0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'encargado1@napoli.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Mateo Silva - Encargado Napoli","email":"encargado1@napoli.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),
  ('b0000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'encargado2@napoli.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Sofía Herrera - Encargada Napoli","email":"encargado2@napoli.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),

  -- Negocio 3: Burger & Craft Sonora
  ('c0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin@sonora.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Alejandro Peña - Admin Sonora","email":"admin@sonora.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),
  ('c0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'encargado1@sonora.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Andrés Silva - Encargado Sonora","email":"encargado1@sonora.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),
  ('c0000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'encargado2@sonora.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Camila Torres - Encargada Sonora","email":"encargado2@sonora.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),

  -- Clientes de prueba
  ('d0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cliente.maria@loopoint.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"María López - Cliente","email":"cliente.maria@loopoint.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now()),
  ('d0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cliente.juan@loopoint.com', extensions.crypt('Loopoint2026!', extensions.gen_salt('bf', 10)), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"Juan David Castro - Cliente","email":"cliente.juan@loopoint.com","email_verified":true}'::jsonb, '', '', '', '', '', 0, '', '', '', false, false, now(), now())
on conflict (id) do update set
  encrypted_password = excluded.encrypted_password,
  email_confirmed_at = excluded.email_confirmed_at,
  raw_user_meta_data = excluded.raw_user_meta_data;

insert into auth.identities (
  id,
  user_id,
  identity_data,
  provider,
  provider_id,
  last_sign_in_at,
  created_at,
  updated_at
)
select
  u.id,
  u.id,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
  'email',
  u.id::text,
  now(),
  now(),
  now()
from auth.users u
where u.id in (
  'a0000000-0000-4000-8000-000000000001',
  'a0000000-0000-4000-8000-000000000002',
  'a0000000-0000-4000-8000-000000000003',
  'b0000000-0000-4000-8000-000000000001',
  'b0000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000003',
  'c0000000-0000-4000-8000-000000000001',
  'c0000000-0000-4000-8000-000000000002',
  'c0000000-0000-4000-8000-000000000003',
  'd0000000-0000-4000-8000-000000000001',
  'd0000000-0000-4000-8000-000000000002'
)
on conflict (provider, provider_id) do update set
  identity_data = excluded.identity_data,
  updated_at = now();

update public.profiles set nickname = 'santiago.aurora' where id = 'a0000000-0000-4000-8000-000000000001';
update public.profiles set nickname = 'carlos.aurora'   where id = 'a0000000-0000-4000-8000-000000000002';
update public.profiles set nickname = 'valen.aurora'    where id = 'a0000000-0000-4000-8000-000000000003';
update public.profiles set nickname = 'marco.napoli'    where id = 'b0000000-0000-4000-8000-000000000001';
update public.profiles set nickname = 'mateo.napoli'    where id = 'b0000000-0000-4000-8000-000000000002';
update public.profiles set nickname = 'sofia.napoli'    where id = 'b0000000-0000-4000-8000-000000000003';
update public.profiles set nickname = 'alejandro.sonora' where id = 'c0000000-0000-4000-8000-000000000001';
update public.profiles set nickname = 'andres.sonora'   where id = 'c0000000-0000-4000-8000-000000000002';
update public.profiles set nickname = 'camila.sonora'   where id = 'c0000000-0000-4000-8000-000000000003';
update public.profiles set nickname = 'maria.lopez'     where id = 'd0000000-0000-4000-8000-000000000001';
update public.profiles set nickname = 'juan.castro'     where id = 'd0000000-0000-4000-8000-000000000002';

-- ---------------------------------------------------------------------
-- 3. CREACIÓN DE LOS 3 NEGOCIOS
-- ---------------------------------------------------------------------

insert into public.businesses (
  id,
  name,
  slug,
  timezone,
  operating_days,
  is_active,
  description,
  address,
  neighborhood,
  city,
  phone_whatsapp,
  instagram,
  website,
  created_by
) values
  (
    '11111111-1111-4111-8111-111111111111',
    'Café & Bakery La Aurora',
    'cafe-la-aurora',
    'America/Bogota',
    '{1,2,3,4,5,6,7}',
    true,
    'Cafetería de especialidad, panadería artesanal y desayunos preparados al momento con ingredientes locales.',
    'Calle 72 # 11-45',
    'Chapinero',
    'Bogotá',
    '+573101234567',
    'cafe.laaurora',
    'https://laaurora.com',
    'a0000000-0000-4000-8000-000000000001'
  ),
  (
    '22222222-2222-4222-8222-222222222222',
    'Pizzería Napoli Artesanal',
    'pizzeria-napoli',
    'America/Bogota',
    '{2,3,4,5,6,7}',
    true,
    'Auténtica pizza napolitana al horno de leña, fermentación lenta de 48 horas e ingredientes italianos D.O.P.',
    'Carrera 15 # 85-32',
    'Zona Rosa',
    'Bogotá',
    '+573159876543',
    'napoli_artesanal',
    'https://pizzerianapoli.co',
    'b0000000-0000-4000-8000-000000000001'
  ),
  (
    '33333333-3333-4333-8333-333333333333',
    'Burger & Craft Sonora',
    'sonora-burger',
    'America/Bogota',
    '{1,2,3,4,5,6,7}',
    true,
    'Smash burgers jugosas, papas rústicas crocantes, salsas de la casa y cervezas artesanales tiradas de barril.',
    'Calle 93 # 12-28',
    'Parque de la 93',
    'Bogotá',
    '+573204567890',
    'sonora.burger',
    'https://sonoraburger.co',
    'c0000000-0000-4000-8000-000000000001'
  );

-- ---------------------------------------------------------------------
-- 4. PROGRAMAS DE LOOPOINTS Y PERFILES ECONÓMICOS
-- ---------------------------------------------------------------------

-- Café La Aurora: 1 pt por cada 1.000 COP, vigencia 180 días
insert into public.loyalty_programs (
  business_id, cop_per_point_unit, points_per_cop_unit, points_expiry_days,
  budget_rate, first_purchase_bonus_points, recurrence_bonus_points, referral_bonus_points,
  qr_expiry_hours, is_active, configured_by, configured_at
) values (
  '11111111-1111-4111-8111-111111111111', 1000, 100, 180,
  0.0500, 20, 10, 15,
  24, true, 'a0000000-0000-4000-8000-000000000001', now()
);

insert into public.business_economic_profiles (
  business_id, daily_avg_sales, monthly_operation_days, daily_gain, gross_margin,
  avg_customers_per_day, max_monthly_reward_budget, data_status
) values (
  '11111111-1111-4111-8111-111111111111', 1200000, 30, 480000, 0.65,
  85, 1800000, '{"confirmed": true}'::jsonb
);

-- Pizzería Napoli: 1 pt por cada 2.000 COP, vigencia 365 días
insert into public.loyalty_programs (
  business_id, cop_per_point_unit, points_per_cop_unit, points_expiry_days,
  budget_rate, first_purchase_bonus_points, recurrence_bonus_points, referral_bonus_points,
  qr_expiry_hours, is_active, configured_by, configured_at
) values (
  '22222222-2222-4222-8222-222222222222', 2000, 100, 365,
  0.0400, 30, 15, 20,
  24, true, 'b0000000-0000-4000-8000-000000000001', now()
);

insert into public.business_economic_profiles (
  business_id, daily_avg_sales, monthly_operation_days, daily_gain, gross_margin,
  avg_customers_per_day, max_monthly_reward_budget, data_status
) values (
  '22222222-2222-4222-8222-222222222222', 2800000, 26, 1100000, 0.60,
  60, 3000000, '{"confirmed": true}'::jsonb
);

-- Burger Sonora: 1 pt por cada 1.500 COP, vigencia 120 días
insert into public.loyalty_programs (
  business_id, cop_per_point_unit, points_per_cop_unit, points_expiry_days,
  budget_rate, first_purchase_bonus_points, recurrence_bonus_points, referral_bonus_points,
  qr_expiry_hours, is_active, configured_by, configured_at
) values (
  '33333333-3333-4333-8333-333333333333', 1500, 100, 120,
  0.0500, 25, 10, 15,
  24, true, 'c0000000-0000-4000-8000-000000000001', now()
);

insert into public.business_economic_profiles (
  business_id, daily_avg_sales, monthly_operation_days, daily_gain, gross_margin,
  avg_customers_per_day, max_monthly_reward_budget, data_status
) values (
  '33333333-3333-4333-8333-333333333333', 3500000, 30, 1400000, 0.58,
  110, 4500000, '{"confirmed": true}'::jsonb
);

-- ---------------------------------------------------------------------
-- 5. MEMBRESÍAS Y ROLES (ADMINISTRADORES Y 2 ENCARGADOS POR NEGOCIO)
--    Incluye también las cuentas Google de Leonardo como admin de los 3.
-- ---------------------------------------------------------------------

insert into public.business_memberships (
  business_id, user_id, role, can_approve_redemptions, created_by
) values
  -- ================== NEGOCIO 1: Café La Aurora ==================
  ('11111111-1111-4111-8111-111111111111', 'a0000000-0000-4000-8000-000000000001', 'admin', true, 'a0000000-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111111', 'a0000000-0000-4000-8000-000000000002', 'encargado', true, 'a0000000-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111111', 'a0000000-0000-4000-8000-000000000003', 'encargado', true, 'a0000000-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111111', '1db7e5c4-9018-4dee-bc99-f6376edf1936', 'admin', true, 'a0000000-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111111', 'b9cf226a-be74-433b-95bf-97006236a637', 'admin', true, 'a0000000-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111111', 'd0000000-0000-4000-8000-000000000001', 'cliente', false, 'a0000000-0000-4000-8000-000000000001'),

  -- ================== NEGOCIO 2: Pizzería Napoli ==================
  ('22222222-2222-4222-8222-222222222222', 'b0000000-0000-4000-8000-000000000001', 'admin', true, 'b0000000-0000-4000-8000-000000000001'),
  ('22222222-2222-4222-8222-222222222222', 'b0000000-0000-4000-8000-000000000002', 'encargado', true, 'b0000000-0000-4000-8000-000000000001'),
  ('22222222-2222-4222-8222-222222222222', 'b0000000-0000-4000-8000-000000000003', 'encargado', true, 'b0000000-0000-4000-8000-000000000001'),
  ('22222222-2222-4222-8222-222222222222', '1db7e5c4-9018-4dee-bc99-f6376edf1936', 'admin', true, 'b0000000-0000-4000-8000-000000000001'),
  ('22222222-2222-4222-8222-222222222222', 'b9cf226a-be74-433b-95bf-97006236a637', 'admin', true, 'b0000000-0000-4000-8000-000000000001'),
  ('22222222-2222-4222-8222-222222222222', 'd0000000-0000-4000-8000-000000000002', 'cliente', false, 'b0000000-0000-4000-8000-000000000001'),

  -- ================== NEGOCIO 3: Burger & Craft Sonora ============
  ('33333333-3333-4333-8333-333333333333', 'c0000000-0000-4000-8000-000000000001', 'admin', true, 'c0000000-0000-4000-8000-000000000001'),
  ('33333333-3333-4333-8333-333333333333', 'c0000000-0000-4000-8000-000000000002', 'encargado', true, 'c0000000-0000-4000-8000-000000000001'),
  ('33333333-3333-4333-8333-333333333333', 'c0000000-0000-4000-8000-000000000003', 'encargado', true, 'c0000000-0000-4000-8000-000000000001'),
  ('33333333-3333-4333-8333-333333333333', '1db7e5c4-9018-4dee-bc99-f6376edf1936', 'admin', true, 'c0000000-0000-4000-8000-000000000001'),
  ('33333333-3333-4333-8333-333333333333', 'b9cf226a-be74-433b-95bf-97006236a637', 'admin', true, 'c0000000-0000-4000-8000-000000000001'),
  ('33333333-3333-4333-8333-333333333333', 'd0000000-0000-4000-8000-000000000001', 'cliente', false, 'c0000000-0000-4000-8000-000000000001');

-- ---------------------------------------------------------------------
-- 6. CARTAS (PRODUCTOS SIMPLES Y COMBOS)
-- ---------------------------------------------------------------------

-- ==================== CARTA 1: Café La Aurora ====================
insert into public.products (id, business_id, name, description, price_cop, cost_cop, is_active, kind) values
  ('11110001-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Café Americano Especialidad', 'Doble shot de espresso de origen Huila con agua filtrada a 92°C.', 6500, 1800, true, 'simple'),
  ('11110001-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'Cappuccino Vainilla', 'Espresso, leche vaporizada sedosa y toque sutil de vainilla de Madagascar.', 9500, 2800, true, 'simple'),
  ('11110001-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'Croissant Artesanal de Almendras', 'Hojaldre 100% mantequilla relleno y cubierto con crema de almendras tostadas.', 11000, 3500, true, 'simple'),
  ('11110001-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'Tostadas Francesas Frutos Rojos', 'Pan brioche artesanal, reducción de frutos rojos, miel de maple y crema batida.', 18500, 6000, true, 'simple'),
  ('11110001-0000-4000-8000-000000000005', '11111111-1111-4111-8111-111111111111', 'Sandwich Pavo & Queso Brie', 'En pan ciabatta rústico, pechuga de pavo horneada, queso brie fundido y rúcula.', 22000, 8000, true, 'simple'),
  ('11110001-0000-4000-8000-000000000006', '11111111-1111-4111-8111-111111111111', 'Jugo Natural de Naranja', 'Exprimido al momento con naranjas valencianas frescas de cosecha.', 7000, 2000, true, 'simple'),
  ('11110001-0000-4000-8000-000000000007', '11111111-1111-4111-8111-111111111111', 'Galleta Red Velvet & Chocolate Blanco', 'Galleta horneada con centro suave de chocolate blanco belga.', 6000, 1500, true, 'simple'),
  -- Combo Desayuno Aurora
  ('11110001-0000-4000-8000-000000000099', '11111111-1111-4111-8111-111111111111', 'Combo Desayuno Aurora', 'Un Croissant de Almendras + Cappuccino Vainilla a precio especial.', 18000, 6300, true, 'combo');

insert into public.product_combo_items (combo_id, component_product_id, quantity) values
  ('11110001-0000-4000-8000-000000000099', '11110001-0000-4000-8000-000000000003', 1),
  ('11110001-0000-4000-8000-000000000099', '11110001-0000-4000-8000-000000000002', 1);

-- ==================== CARTA 2: Pizzería Napoli ====================
insert into public.products (id, business_id, name, description, price_cop, cost_cop, is_active, kind) values
  ('22220002-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'Pizza Margherita Clásica', 'Salsa de tomate San Marzano, mozzarella fior di latte, albahaca fresca y aceite de oliva virgen extra.', 34000, 10000, true, 'simple'),
  ('22220002-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222', 'Pizza Pepperoni & Miel Picante', 'Pepperoni artesanal italiano crujiente con hilo de miel infusionada con ají habanero.', 38000, 12000, true, 'simple'),
  ('22220002-0000-4000-8000-000000000003', '22222222-2222-4222-8222-222222222222', 'Pizza Cuatro Quesos', 'Mozzarella, gorgonzola cremoso, fontina fundida y parmesano reggiano de 24 meses.', 42000, 14000, true, 'simple'),
  ('22220002-0000-4000-8000-000000000004', '22222222-2222-4222-8222-222222222222', 'Bruschettas Pomodoro (3 uds)', 'Pan de masa madre tostado al horno de leña, tomate concassé, ajo confitado y albahaca.', 16000, 4500, true, 'simple'),
  ('22220002-0000-4000-8000-000000000005', '22222222-2222-4222-8222-222222222222', 'Tiramisú Tradicional de la Casa', 'Bizcocho savoiardi remojado en café espresso, licor amaretto y crema suave de mascarpone.', 15000, 4800, true, 'simple'),
  ('22220002-0000-4000-8000-000000000006', '22222222-2222-4222-8222-222222222222', 'Soda Saborizada Frutos Rojos', 'Soda artesanal con macerado casero de moras, fresas y arándanos silvestres.', 8500, 2200, true, 'simple'),
  ('22220002-0000-4000-8000-000000000007', '22222222-2222-4222-8222-222222222222', 'Cerveza Birra Moretti 330ml', 'Cerveza rubia lager tradicional italiana de sabor refrescante y equilibrado.', 12000, 4200, true, 'simple'),
  -- Combo Dúo Napolitano
  ('22220002-0000-4000-8000-000000000099', '22222222-2222-4222-8222-222222222222', 'Combo Dúo Napolitano', 'Pizza Margherita + Bruschettas Pomodoro + 2 Sodas Frutos Rojos.', 54000, 18900, true, 'combo');

insert into public.product_combo_items (combo_id, component_product_id, quantity) values
  ('22220002-0000-4000-8000-000000000099', '22220002-0000-4000-8000-000000000001', 1),
  ('22220002-0000-4000-8000-000000000099', '22220002-0000-4000-8000-000000000004', 1),
  ('22220002-0000-4000-8000-000000000099', '22220002-0000-4000-8000-000000000006', 2);

-- ==================== CARTA 3: Burger Sonora ====================
insert into public.products (id, business_id, name, description, price_cop, cost_cop, is_active, kind) values
  ('33330003-0000-4000-8000-000000000001', '33333333-3333-4333-8333-333333333333', 'Hamburguesa Sonora Smash Doble', 'Dos medallones de 110g smash de res Angus, doble cheddar americano, pepinillos y salsa Sonora.', 28000, 9500, true, 'simple'),
  ('33330003-0000-4000-8000-000000000002', '33333333-3333-4333-8333-333333333333', 'Hamburguesa Bacon Bourbon BBQ', 'Carne Angus 180g, tocineta ahumada crujiente caramelizada en salsa BBQ bourbon casera y queso gouda.', 32000, 11000, true, 'simple'),
  ('33330003-0000-4000-8000-000000000003', '33333333-3333-4333-8333-333333333333', 'Papas Rústicas Trufadas', 'Papas corte grueso con cáscara, aceite de trufa blanca, queso parmesano y perejil fresco.', 14000, 3800, true, 'simple'),
  ('33330003-0000-4000-8000-000000000004', '33333333-3333-4333-8333-333333333333', 'Aros de Cebolla Crocantes', 'Aros de cebolla morada rebosados en tempura de cerveza y acompañados de salsa tártara ahumada.', 12000, 3200, true, 'simple'),
  ('33330003-0000-4000-8000-000000000005', '33333333-3333-4333-8333-333333333333', 'Cerveza Artesanal IPA 330ml', 'Cerveza lupulada de la casa con intensas notas cítricas y amargor equilibrado.', 14500, 5000, true, 'simple'),
  ('33330003-0000-4000-8000-000000000006', '33333333-3333-4333-8333-333333333333', 'Limonada Natural de Hierbabuena', 'Zumo de limón recién exprimido, hojas de hierbabuena fresca y hielo frappé.', 7500, 1900, true, 'simple'),
  ('33330003-0000-4000-8000-000000000007', '33333333-3333-4333-8333-333333333333', 'Malteada de Caramelo Salado', 'Helado de crema de vainilla con sirope casero de toffee, flor de sal y crema chantilly.', 13500, 4500, true, 'simple'),
  -- Combo Smash Master
  ('33330003-0000-4000-8000-000000000099', '33333333-3333-4333-8333-333333333333', 'Combo Smash Master', 'Hamburguesa Sonora Smash Doble + Papas Rústicas Trufadas + Cerveza IPA.', 45000, 18300, true, 'combo');

insert into public.product_combo_items (combo_id, component_product_id, quantity) values
  ('33330003-0000-4000-8000-000000000099', '33330003-0000-4000-8000-000000000001', 1),
  ('33330003-0000-4000-8000-000000000099', '33330003-0000-4000-8000-000000000003', 1),
  ('33330003-0000-4000-8000-000000000099', '33330003-0000-4000-8000-000000000005', 1);

-- ---------------------------------------------------------------------
-- 7. RECOMPENSAS DEL CATÁLOGO DE LOOPOINTS
-- ---------------------------------------------------------------------

-- Recompensas Café La Aurora
insert into public.loyalty_rewards (
  business_id, product_id, type, name, description, points_required,
  min_purchase_amount, max_discount_amount, discount_percentage,
  product_price_cop, product_cost_cop, is_active, created_by
) values
  ('11111111-1111-4111-8111-111111111111', '11110001-0000-4000-8000-000000000001', 'free_product', 'Café Americano Especialidad Gratis', 'Disfruta un café americano con tus puntos acumulados.', 45, 0, null, null, 6500, 1800, true, 'a0000000-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111111', '11110001-0000-4000-8000-000000000003', 'free_product', 'Croissant de Almendras Gratis', 'Canjea un delicioso croissant recién horneado.', 75, 0, null, null, 11000, 3500, true, 'a0000000-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111111', null, 'percentage_discount', '15% de Descuento en tu Desayuno', '15% de descuento en consumos superiores a $20.000 COP.', 50, 20000, 10000, 15.00, null, null, true, 'a0000000-0000-4000-8000-000000000001');

-- Recompensas Pizzería Napoli
insert into public.loyalty_rewards (
  business_id, product_id, type, name, description, points_required,
  min_purchase_amount, max_discount_amount, discount_percentage,
  product_price_cop, product_cost_cop, is_active, created_by
) values
  ('22222222-2222-4222-8222-222222222222', '22220002-0000-4000-8000-000000000005', 'free_product', 'Tiramisú Tradicional Gratis', 'Postre tiramisú italiano preparado por nuestro chef.', 55, 0, null, null, 15000, 4800, true, 'b0000000-0000-4000-8000-000000000001'),
  ('22222222-2222-4222-8222-222222222222', '22220002-0000-4000-8000-000000000004', 'free_product', 'Bruschettas Pomodoro Gratis', 'Entrada de 3 bruschettas al horno de leña.', 50, 0, null, null, 16000, 4500, true, 'b0000000-0000-4000-8000-000000000001'),
  ('22222222-2222-4222-8222-222222222222', null, 'fixed_discount', 'Bono Descuento $20.000 COP', 'Bono de $20.000 aplicable en compras mayores a $50.000 COP.', 70, 50000, 20000, null, null, null, true, 'b0000000-0000-4000-8000-000000000001');

-- Recompensas Burger Sonora
insert into public.loyalty_rewards (
  business_id, product_id, type, name, description, points_required,
  min_purchase_amount, max_discount_amount, discount_percentage,
  product_price_cop, product_cost_cop, is_active, created_by
) values
  ('33333333-3333-4333-8333-333333333333', '33330003-0000-4000-8000-000000000003', 'free_product', 'Papas Rústicas Trufadas Gratis', 'Porción completa de papas rústicas trufadas.', 45, 0, null, null, 14000, 3800, true, 'c0000000-0000-4000-8000-000000000001'),
  ('33333333-3333-4333-8333-333333333333', '33330003-0000-4000-8000-000000000005', 'free_product', 'Cerveza Artesanal IPA Gratis', 'Vaso de cerveza artesanal de barril tirada al momento.', 50, 0, null, null, 14500, 5000, true, 'c0000000-0000-4000-8000-000000000001'),
  ('33333333-3333-4333-8333-333333333333', '33330003-0000-4000-8000-000000000001', 'free_product', 'Hamburguesa Sonora Smash Doble Gratis', 'Nuestra burger estrella canjeable con tus loopoints.', 95, 0, null, null, 28000, 9500, true, 'c0000000-0000-4000-8000-000000000001'),
  ('33333333-3333-4333-8333-333333333333', null, 'percentage_discount', '20% Descuento en tu Cuenta', '20% de descuento en consumos superiores a $35.000 COP.', 65, 35000, 15000, 20.00, null, null, true, 'c0000000-0000-4000-8000-000000000001');

-- ---------------------------------------------------------------------
-- 8. CUENTAS DE PUNTOS Y SALDO INICIAL PARA CLIENTE DE PRUEBA
-- ---------------------------------------------------------------------

insert into public.loyalty_point_accounts (id, business_id, customer_id, balance) values
  ('d0000001-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'd0000000-0000-4000-8000-000000000001', 120),
  ('d0000001-0000-4000-8000-000000000002', '33333333-3333-4333-8333-333333333333', 'd0000000-0000-4000-8000-000000000001', 80),
  ('d0000002-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'd0000000-0000-4000-8000-000000000002', 60);

insert into public.loyalty_point_transactions (
  business_id, account_id, movement_type, points, reference_type, reference_id,
  reason, idempotency_key, created_by
) values
  ('11111111-1111-4111-8111-111111111111', 'd0000001-0000-4000-8000-000000000001', 'bonus_credit', 120, 'welcome', null, 'Bono inicial de bienvenida y fidelidad', 'seed-bonus-aurora-001', 'a0000000-0000-4000-8000-000000000001'),
  ('33333333-3333-4333-8333-333333333333', 'd0000001-0000-4000-8000-000000000002', 'bonus_credit', 80, 'welcome', null, 'Bono inicial de bienvenida', 'seed-bonus-sonora-001', 'c0000000-0000-4000-8000-000000000001'),
  ('22222222-2222-4222-8222-222222222222', 'd0000002-0000-4000-8000-000000000001', 'bonus_credit', 60, 'welcome', null, 'Bono inicial de bienvenida', 'seed-bonus-napoli-001', 'b0000000-0000-4000-8000-000000000001');

commit;
