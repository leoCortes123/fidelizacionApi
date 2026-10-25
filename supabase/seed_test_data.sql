-- =====================================================================
-- Datos de prueba: un negocio completo (Tacos Don Pepe)
-- Ejecutar en el SQL Editor de Supabase Dashboard (bypasa RLS)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Usuarios de prueba (perfiles)
--    NOTA: Estos UUIDs deben coincidir con usuarios creados en
--    Supabase Auth (auth.users). Si no existen, créalos primero en
--    Authentication > Users y usa sus IDs reales.
-- ---------------------------------------------------------------------
insert into public.profiles (id, full_name, email) values
  ('fbc602d0-afa6-40b8-adba-e13c9b8c9558', 'Admin Don Pepe', 'admin@tacosdonpepe.com'),
  ('95bc0d6b-ebde-470b-90d3-52bdc192d2f0', 'Cliente María', 'maria@cliente.com')
on conflict (id) do update set
  full_name = excluded.full_name,
  email = excluded.email;

-- Roles de aplicación
insert into public.user_roles (user_id, role) values
  ('fbc602d0-afa6-40b8-adba-e13c9b8c9558', 'admin')
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 2. Negocio
-- ---------------------------------------------------------------------
insert into public.businesses (id, name, slug, operating_days, is_active, created_by) values
  ('cccccccc-cccc-4cccc-8cccc-cccccccccccc', 'Tacos Don Pepe', 'tacos-don-pepe', '{1,2,3,4,5,6}', true, 'fbc602d0-afa6-40b8-adba-e13c9b8c9558')
on conflict (slug) do update set
  name = excluded.name,
  is_active = excluded.is_active;

-- Membresías
insert into public.business_memberships (business_id, user_id, role, can_approve_redemptions, created_by) values
  ('cccccccc-cccc-4cccc-8cccc-cccccccccccc', 'fbc602d0-afa6-40b8-adba-e13c9b8c9558', 'admin', true, 'fbc602d0-afa6-40b8-adba-e13c9b8c9558'),
  ('cccccccc-cccc-4cccc-8cccc-cccccccccccc', '95bc0d6b-ebde-470b-90d3-52bdc192d2f0', 'cliente', false, 'fbc602d0-afa6-40b8-adba-e13c9b8c9558')
on conflict (business_id, user_id) do update set
  role = excluded.role,
  can_approve_redemptions = excluded.can_approve_redemptions;

-- ---------------------------------------------------------------------
-- 3. Programa de lealtad del negocio
-- ---------------------------------------------------------------------
insert into public.loyalty_programs (
  business_id, cop_per_point_unit, points_per_cop_unit, points_expiry_days,
  budget_rate, first_purchase_bonus_points, recurrence_bonus_points,
  referral_bonus_points, qr_expiry_hours, is_active, configured_by
) values (
  'cccccccc-cccc-4cccc-8cccc-cccccccccccc', 1000, 100, 365, 0.0100, 0, 0, 0, 24, true,
  'fbc602d0-afa6-40b8-adba-e13c9b8c9558'
) on conflict (business_id) do update set
  cop_per_point_unit = excluded.cop_per_point_unit,
  points_per_cop_unit = excluded.points_per_cop_unit,
  points_expiry_days = excluded.points_expiry_days,
  budget_rate = excluded.budget_rate,
  qr_expiry_hours = excluded.qr_expiry_hours,
  is_active = excluded.is_active,
  configured_by = excluded.configured_by;

-- ---------------------------------------------------------------------
-- 4. Productos de la carta
-- ---------------------------------------------------------------------
insert into public.products (business_id, name, description, price_cop, cost_cop, is_active) values
  ('cccccccc-cccc-4cccc-8cccc-cccccccccccc', 'Taco de suadero', 'Taco de suadero con cebolla y cilantro', 12000, 4000, true),
  ('cccccccc-cccc-4cccc-8cccc-cccccccccccc', 'Taco de guisado', 'Taco de guisado con doble tortilla', 10000, 3500, true),
  ('cccccccc-cccc-4cccc-8cccc-cccccccccccc', 'Agua fresca', 'Horchata o jamaica', 3000, 800, true),
  ('cccccccc-cccc-4cccc-8cccc-cccccccccccc', 'Consomé', 'Consomé de res', 5000, 1500, true)
on conflict (business_id, lower(btrim(name))) do nothing;

-- Obtener IDs de productos para las recompensas (usamos CTE para no repetir)
-- Insertamos recompensas vinculadas a productos

-- ---------------------------------------------------------------------
-- 5. Recompensas del catálogo
-- ---------------------------------------------------------------------
-- Primero obtenemos los product_ids
with p_suadero as (
  select id from public.products where business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc' and name = 'Taco de suadero' limit 1
),
p_guisado as (
  select id from public.products where business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc' and name = 'Taco de guisado' limit 1
),
p_agua as (
  select id from public.products where business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc' and name = 'Agua fresca' limit 1
),
p_consome as (
  select id from public.products where business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc' and name = 'Consomé' limit 1
)
insert into public.loyalty_rewards (
  business_id, product_id, type, name, description, points_required,
  min_purchase_amount, max_discount_amount, discount_percentage,
  product_price_cop, product_cost_cop, is_active
)
select
  'cccccccc-cccc-4cccc-8cccc-cccccccccccc',
  p.id,
  'free_product',
  p.name,
  'Canjea por este producto con puntos',
  case
    when p.name = 'Taco de suadero' then 60
    when p.name = 'Taco de guisado' then 50
    when p.name = 'Agua fresca' then 25
    when p.name = 'Consomé' then 40
  end,
  0, null, null,
  p.price_cop, p.cost_cop, true
from (
  select id, name, price_cop, cost_cop from p_suadero
  union all select id, name, price_cop, cost_cop from p_guisado
  union all select id, name, price_cop, cost_cop from p_agua
  union all select id, name, price_cop, cost_cop from p_consome
) p
on conflict (business_id, lower(btrim(name))) do nothing;

-- ---------------------------------------------------------------------
-- 6. Cuenta de puntos del cliente
-- ---------------------------------------------------------------------
insert into public.loyalty_point_accounts (business_id, customer_id, balance) values
  ('cccccccc-cccc-4cccc-8cccc-cccccccccccc', '95bc0d6b-ebde-470b-90d3-52bdc192d2f0', 0)
on conflict (business_id, customer_id) do update set balance = 0;

-- ---------------------------------------------------------------------
-- 7. Transacciones de puntos (saldo del cliente)
-- ---------------------------------------------------------------------
-- 7.1 Bonus inicial de bienvenida (+100 puntos)
insert into public.loyalty_point_transactions (
  business_id, account_id, movement_type, points, reference_type, reference_id,
  reason, idempotency_key, created_by
)
select
  'cccccccc-cccc-4cccc-8cccc-cccccccccccc',
  a.id,
  'bonus_credit', 100, 'welcome', null,
  'Bono de bienvenida', 'test-bonus-welcome-001', 'fbc602d0-afa6-40b8-adba-e13c9b8c9558'
from public.loyalty_point_accounts a
where a.business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc'
  and a.customer_id = '95bc0d6b-ebde-470b-90d3-52bdc192d2f0'
on conflict (idempotency_key) do nothing;

-- 7.2 Compra de prueba: 15000 COP -> 15 puntos (cop_per_point_unit = 1000)
insert into public.loyalty_purchase_events (
  business_id, account_id, purchase_id, amount_cop, eligible_amount_cop,
  points_earned, rule_version
)
select
  'cccccccc-cccc-4cccc-8cccc-cccccccccccc',
  a.id,
  null, 15000, 15000, 15, 'v1'
from public.loyalty_point_accounts a
where a.business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc'
  and a.customer_id = '95bc0d6b-ebde-470b-90d3-52bdc192d2f0'
on conflict do nothing;

insert into public.loyalty_point_transactions (
  business_id, account_id, movement_type, points, reference_type, reference_id,
  reason, idempotency_key, created_by
)
select
  'cccccccc-cccc-4cccc-8cccc-cccccccccccc',
  a.id,
  'purchase_credit', 15, 'purchase', null,
  'Compra de 15.000 COP - 15 puntos', 'test-purchase-credit-001', '95bc0d6b-ebde-470b-90d3-52bdc192d2f0'
from public.loyalty_point_accounts a
where a.business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc'
  and a.customer_id = '95bc0d6b-ebde-470b-90d3-52bdc192d2f0'
on conflict (idempotency_key) do nothing;

-- 7.3 Redención de prueba: canje de "Agua fresca" (25 puntos) -> pendiente
-- Obtener reward_id de Agua fresca
with r_agua as (
  select id from public.loyalty_rewards
  where business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc' and name = 'Agua fresca' limit 1
),
acc as (
  select id from public.loyalty_point_accounts
  where business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc'
    and customer_id = '95bc0d6b-ebde-470b-90d3-52bdc192d2f0'
)
insert into public.loyalty_redemptions (
  business_id, account_id, reward_id, reward_name, reward_type, points_spent,
  code, status, idempotency_key, created_by
)
select
  'cccccccc-cccc-4cccc-8cccc-cccccccccccc',
  acc.id,
  r.id,
  'Agua fresca',
  'free_product',
  25,
  'REDEEM001',
  'pending',
  'test-redemption-agua-001',
  '95bc0d6b-ebde-470b-90d3-52bdc192d2f0'
from r_agua, acc
on conflict (idempotency_key) do nothing;

-- Transacción de débito por la redención pendiente
with red as (
  select id from public.loyalty_redemptions where code = 'REDEEM001' limit 1
),
acc as (
  select id from public.loyalty_point_accounts
  where business_id = 'cccccccc-cccc-4cccc-8cccc-cccccccccccc'
    and customer_id = '95bc0d6b-ebde-470b-90d3-52bdc192d2f0'
)
insert into public.loyalty_point_transactions (
  business_id, account_id, movement_type, points, reference_type, reference_id,
  reason, idempotency_key, created_by
)
select
  'cccccccc-cccc-4cccc-8cccc-cccccccccccc',
  acc.id,
  'redemption_debit', -25, 'redemption', red.id,
  'Canje: Agua fresca (pendiente)', 'test-redemption-debit-001', '95bc0d6b-ebde-470b-90d3-52bdc192d2f0'
from red, acc
on conflict (idempotency_key) do nothing;

-- Token QR para la redención
with red as (
  select id from public.loyalty_redemptions where code = 'REDEEM001' limit 1
)
insert into public.loyalty_redemption_tokens (
  business_id, redemption_id, token_hash, expires_at, consumed_at
)
select
  'cccccccc-cccc-4cccc-8cccc-cccccccccccc',
  red.id,
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  now() + interval '24 hours',
  null
from red
on conflict (token_hash) do nothing;

-- ---------------------------------------------------------------------
-- 8. Mensaje de resumen
-- ---------------------------------------------------------------------
do $$
begin
  raise notice 'Datos de prueba creados:';
  raise notice '  Negocio: Tacos Don Pepe (cccccccc-cccc-4cccc-8cccc-cccccccccccc)';
  raise notice '  Admin: fbc602d0-afa6-40b8-adba-e13c9b8c9558 (admin@tacosdonpepe.com)';
  raise notice '  Cliente: 95bc0d6b-ebde-470b-90d3-52bdc192d2f0 (maria@cliente.com)';
  raise notice '  Saldo cliente: 90 puntos (100 bono + 15 compra - 25 redención pendiente)';
end $$;
