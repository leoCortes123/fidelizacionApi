-- =====================================================================
-- Aislamiento por negocio y módulo de fidelización por puntos
-- Fecha: 24/10/2026
--
-- Se añaden las entidades de negocio y el programa de puntos sin
-- modificar ni eliminar tablas ni columnas existentes.
-- Todas las tablas nuevas llevan business_id para aislamiento RLS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tipos enumerados propios del módulo de fidelización por negocio
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'business_role') then
    create type public.business_role as enum ('admin', 'encargado', 'cliente');
  end if;

  if not exists (select 1 from pg_type where typname = 'loyalty_reward_type') then
    create type public.loyalty_reward_type as enum (
      'free_product',
      'fixed_discount',
      'percentage_discount',
      'configurable_benefit'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'point_movement_type') then
    create type public.point_movement_type as enum (
      'purchase_credit',
      'redemption_debit',
      'redemption_refund',
      'expiry_debit',
      'admin_adjustment',
      'bonus_credit'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'redemption_request_status') then
    create type public.redemption_request_status as enum (
      'pending',
      'approved',
      'delivered',
      'cancelled',
      'expired'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'economic_data_status') then
    create type public.economic_data_status as enum (
      'confirmed',
      'estimated',
      'unknown'
    );
  end if;
end
$$;

-- ---------------------------------------------------------------------
-- Negocio (entidad de aislamiento multiempresa)
-- ---------------------------------------------------------------------
create table if not exists public.businesses (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null,
  slug text not null unique,
  timezone text not null default 'America/Bogota',
  operating_days smallint[] not null default '{1,2,3,4,5,6}',
  is_active boolean not null default true,
  created_by uuid references public.profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint businesses_name_not_blank check (length(btrim(name)) > 0),
  constraint businesses_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

create index businesses_slug_idx on public.businesses (slug);
create index businesses_created_by_idx on public.businesses (created_by);

comment on table public.businesses is 'Entidad de negocio. Aísla todos los datos del programa de fidelización.';
comment on column public.businesses.operating_days is 'Días de operación (1=lunes ... 7=domingo).';

-- ---------------------------------------------------------------------
-- Membresías usuario-negocio (un usuario puede estar en varios negocios)
-- ---------------------------------------------------------------------
create table if not exists public.business_memberships (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.business_role not null default 'cliente',
  can_approve_redemptions boolean not null default false,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, user_id),
  constraint business_memberships_role_valid check (role in ('admin', 'encargado', 'cliente'))
);

create index business_memberships_business_idx on public.business_memberships (business_id, role);
create index business_memberships_user_idx on public.business_memberships (user_id);

comment on table public.business_memberships is 'Relación usuario-negocio con rol y permisos. Un administrador crea encargados y clientes del negocio.';
comment on column public.business_memberships.can_approve_redemptions is 'Permite al encargado aprobar redenciones. Solo el administrador lo activa/desactiva.';

-- ---------------------------------------------------------------------
-- Productos de la carta (por negocio; se reutilizan para recompensas)
-- ---------------------------------------------------------------------
create table if not exists public.products (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null,
  description text,
  price_cop integer not null,
  cost_cop integer,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint products_price_positive check (price_cop > 0 and price_cop <= 100000000),
  constraint products_cost_nonnegative check (cost_cop is null or cost_cop >= 0)
);

create index products_business_idx on public.products (business_id, is_active);
create unique index products_name_business_unique
  on public.products (business_id, lower(btrim(name)));

comment on table public.products is 'Carta de productos por negocio. Precios y costos reutilizados por recompensas y acumulaciones.';

-- ---------------------------------------------------------------------
-- Programa de puntos (configuración por negocio)
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_programs (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade unique,
  cop_per_point_unit integer not null default 1000,
  points_per_cop_unit integer not null default 100,
  points_expiry_days integer not null default 365,
  budget_rate numeric(5,4) not null default 0.0100,
  first_purchase_bonus_points integer not null default 0,
  recurrence_bonus_points integer not null default 0,
  referral_bonus_points integer not null default 0,
  qr_expiry_hours integer not null default 24,
  is_active boolean not null default false,
  configured_by uuid references public.profiles (id) on delete set null,
  configured_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint loyalty_programs_cop_per_point check (cop_per_point_unit between 100 and 1000000),
  constraint loyalty_programs_points_per_cop check (points_per_cop_unit between 1 and 1000000),
  constraint loyalty_programs_budget_rate check (budget_rate >= 0 and budget_rate <= 1),
  constraint loyalty_programs_qr_expiry check (qr_expiry_hours between 1 and 168)
);

create index loyalty_programs_business_idx on public.loyalty_programs (business_id);

comment on table public.loyalty_programs is 'Reglas configurables del programa de puntos de un negocio.';
comment on column public.loyalty_programs.budget_rate is 'Tasa de presupuesto de referencia (fracción de ventas mensuales).';

-- ---------------------------------------------------------------------
-- Catálogo de recompensas (por negocio, vinculado a productos de la carta)
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_rewards (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  product_id uuid references public.products (id) on delete set null,
  type public.loyalty_reward_type not null,
  name text not null,
  description text not null default '',
  points_required integer not null,
  min_purchase_amount integer not null default 0,
  max_discount_amount integer,
  discount_percentage numeric(5,2),
  product_price_cop integer,
  product_cost_cop integer,
  is_active boolean not null default true,
  valid_from timestamptz,
  valid_until timestamptz,
  max_redemptions_per_customer integer,
  max_redemptions_per_period integer,
  redemption_period_days integer,
  total_redemption_limit integer,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint loyalty_rewards_points_positive check (points_required > 0 and points_required <= 10000000),
  constraint loyalty_rewards_name_not_blank check (length(btrim(name)) > 0),
  constraint loyalty_rewards_min_purchase check (min_purchase_amount >= 0),
  constraint loyalty_rewards_max_discount check (max_discount_amount is null or max_discount_amount >= 0),
  constraint loyalty_rewards_discount_pct check (
    discount_percentage is null
    or (discount_percentage > 0 and discount_percentage <= 100)
  ),
  constraint loyalty_rewards_validity check (
    valid_from is null or valid_until is null or valid_until > valid_from
  ),
  constraint loyalty_rewards_free_product_links_product check (
    type <> 'free_product' or product_id is not null
  )
);

create index loyalty_rewards_business_idx on public.loyalty_rewards (business_id, is_active);
create unique index loyalty_rewards_name_business_unique
  on public.loyalty_rewards (business_id, lower(btrim(name)));

comment on table public.loyalty_rewards is 'Catálogo de recompensas por negocio. Para producto gratuito se vincula a products y se copian precio y costo.';

-- ---------------------------------------------------------------------
-- Cuenta de puntos (una por cliente y negocio)
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_point_accounts (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  customer_id uuid not null references public.profiles (id) on delete cascade,
  balance integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, customer_id),
  constraint loyalty_point_accounts_balance_nonnegative check (balance >= 0)
);

create index loyalty_point_accounts_business_idx on public.loyalty_point_accounts (business_id, customer_id);
create index loyalty_point_accounts_customer_idx on public.loyalty_point_accounts (customer_id);

comment on table public.loyalty_point_accounts is 'Saldo transaccional proyectado del libro. La fuente de verdad son loyalty_point_transactions.';
comment on column public.loyalty_point_accounts.balance is 'Proyección transaccional; debe mantenerse consistente con loyalty_point_transactions.';

-- ---------------------------------------------------------------------
-- Libro de movimientos de puntos (inmutable, fuente de verdad)
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_point_transactions (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  account_id uuid not null references public.loyalty_point_accounts (id) on delete cascade,
  movement_type public.point_movement_type not null,
  points integer not null,
  reference_type text,
  reference_id uuid,
  reason text,
  idempotency_key text not null unique,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint loyalty_point_transactions_nonzero check (points <> 0),
  constraint loyalty_point_transactions_reason_length check (reason is null or length(reason) <= 300)
);

create unique index loyalty_point_transactions_one_credit_per_purchase
  on public.loyalty_point_transactions (reference_id)
  where movement_type = 'purchase_credit' and reference_type = 'purchase';
create unique index loyalty_point_transactions_one_debit_per_redemption
  on public.loyalty_point_transactions (reference_id)
  where movement_type = 'redemption_debit' and reference_type = 'redemption';
create unique index loyalty_point_transactions_one_refund_per_redemption
  on public.loyalty_point_transactions (reference_id)
  where movement_type = 'redemption_refund' and reference_type = 'redemption';
create index loyalty_point_transactions_account_idx
  on public.loyalty_point_transactions (account_id, created_at desc);
create index loyalty_point_transactions_business_idx
  on public.loyalty_point_transactions (business_id, created_at desc);

comment on table public.loyalty_point_transactions is 'Libro mayor inmutable. El saldo es la suma de movimientos; no se eliminan movimientos contables.';

-- ---------------------------------------------------------------------
-- Redenciones (solicitudes y confirmaciones por negocio)
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_redemptions (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  account_id uuid not null references public.loyalty_point_accounts (id) on delete cascade,
  reward_id uuid not null references public.loyalty_rewards (id) on delete restrict,
  reward_name text not null,
  reward_type public.loyalty_reward_type not null,
  points_spent integer not null,
  code text not null unique,
  status public.redemption_request_status not null default 'pending',
  idempotency_key text not null unique,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  approved_by uuid references public.profiles (id) on delete set null,
  approved_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  constraint loyalty_redemptions_points_positive check (points_spent > 0),
  constraint loyalty_redemptions_reason_length check (cancellation_reason is null or length(cancellation_reason) <= 300)
);

create index loyalty_redemptions_business_idx on public.loyalty_redemptions (business_id, created_at desc);
create index loyalty_redemptions_account_idx on public.loyalty_redemptions (account_id, created_at desc);
create index loyalty_redemptions_status_idx on public.loyalty_redemptions (status, created_at);
create index loyalty_redemptions_code_idx on public.loyalty_redemptions (code);

comment on table public.loyalty_redemptions is 'Solicitudes y redenciones confirmadas. El código es el QR entregado al cliente.';

-- ---------------------------------------------------------------------
-- Tokens QR de redención (solo hash, sin datos personales ni saldos)
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_redemption_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  redemption_id uuid not null references public.loyalty_redemptions (id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint loyalty_redemption_tokens_hash_format check (token_hash ~ '^[a-f0-9]{64}$')
);

create index loyalty_redemption_tokens_redemption_idx on public.loyalty_redemption_tokens (redemption_id);
create index loyalty_redemption_tokens_expires_idx on public.loyalty_redemption_tokens (expires_at);

comment on table public.loyalty_redemption_tokens is 'Tokens de QR vinculados a negocio y redención. Solo se almacena el hash SHA-256; nunca datos personales ni saldos.';

-- ---------------------------------------------------------------------
-- Perfil económico del negocio
-- ---------------------------------------------------------------------
create table if not exists public.business_economic_profiles (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade unique,
  daily_avg_sales integer,
  monthly_operation_days integer,
  daily_gain integer,
  gross_margin numeric(5,2),
  avg_customers_per_day integer,
  max_monthly_reward_budget integer,
  data_status jsonb not null default '{}'::jsonb,
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint business_economic_profiles_sales_nonneg check (daily_avg_sales is null or daily_avg_sales >= 0),
  constraint business_economic_profiles_margin check (gross_margin is null or (gross_margin >= 0 and gross_margin <= 100))
);

create index business_economic_profiles_business_idx on public.business_economic_profiles (business_id);

comment on table public.business_economic_profiles is 'Datos económicos del negocio para calcular presupuesto de recompensas. Cada dato puede estar confirmado, estimado o desconocido.';

-- ---------------------------------------------------------------------
-- Eventos de compra vinculados a negocio (evita acumulaciones duplicadas)
-- ---------------------------------------------------------------------
create table if not exists public.loyalty_purchase_events (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  account_id uuid not null references public.loyalty_point_accounts (id) on delete cascade,
  purchase_id uuid references public.purchases (id) on delete set null,
  amount_cop integer not null,
  eligible_amount_cop integer not null,
  points_earned integer not null,
  rule_version text,
  created_at timestamptz not null default now(),
  constraint loyalty_purchase_events_amount_positive check (amount_cop > 0),
  constraint loyalty_purchase_events_eligible_not_negative check (eligible_amount_cop >= 0),
  constraint loyalty_purchase_events_points_nonneg check (points_earned >= 0)
);

create index loyalty_purchase_events_business_idx on public.loyalty_purchase_events (business_id, created_at desc);
create index loyalty_purchase_events_account_idx on public.loyalty_purchase_events (account_id, created_at desc);
create unique index loyalty_purchase_events_one_per_purchase
  on public.loyalty_purchase_events (purchase_id)
  where purchase_id is not null;

comment on table public.loyalty_purchase_events is 'Eventos de compra para acumulación de puntos. Evita duplicar puntos al reprocesar una compra.';

-- ---------------------------------------------------------------------
-- Auditoría de operaciones por negocio
-- ---------------------------------------------------------------------
create table if not exists public.business_audit_logs (
  id uuid primary key default extensions.gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  actor_id uuid references public.profiles (id) on delete set null,
  actor_email text,
  operation text not null,
  entity_type text not null,
  entity_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index business_audit_logs_business_idx on public.business_audit_logs (business_id, created_at desc);
create index business_audit_logs_entity_idx on public.business_audit_logs (entity_type, entity_id);

comment on table public.business_audit_logs is 'Auditoría de operaciones de fidelización por negocio. Quién modifica reglas, aprueba redenciones, motivos de reversos.';

-- ---------------------------------------------------------------------
-- Triggers de updated_at (mismo patrón que el esquema existente)
-- ---------------------------------------------------------------------
create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger businesses_touch_updated_at
  before update on public.businesses
  for each row execute function private.touch_updated_at();

create trigger business_memberships_touch_updated_at
  before update on public.business_memberships
  for each row execute function private.touch_updated_at();

create trigger products_touch_updated_at
  before update on public.products
  for each row execute function private.touch_updated_at();

create trigger loyalty_programs_touch_updated_at
  before update on public.loyalty_programs
  for each row execute function private.touch_updated_at();

create trigger loyalty_rewards_touch_updated_at
  before update on public.loyalty_rewards
  for each row execute function private.touch_updated_at();

create trigger loyalty_point_accounts_touch_updated_at
  before update on public.loyalty_point_accounts
  for each row execute function private.touch_updated_at();

create trigger business_economic_profiles_touch_updated_at
  before update on public.business_economic_profiles
  for each row execute function private.touch_updated_at();
