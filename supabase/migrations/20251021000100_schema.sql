-- =====================================================================
-- Esquema base del programa de fidelización
-- Dinero: integer en pesos colombianos (COP no usa centavos en la práctica).
-- Tiempo: timestamptz; la interfaz presenta America/Bogota.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'app_role') then
    create type public.app_role as enum ('customer', 'registrar', 'admin');
  end if;
  if not exists (select 1 from pg_type where typname = 'purchase_status') then
    create type public.purchase_status as enum ('pending_claim', 'claimed', 'expired', 'cancelled');
  end if;
  if not exists (select 1 from pg_type where typname = 'points_movement_type') then
    create type public.points_movement_type as enum (
      'purchase_credit', 'redemption_debit', 'redemption_refund', 'expiry_debit', 'admin_adjustment'
    );
  end if;
  if not exists (select 1 from pg_type where typname = 'redemption_status') then
    create type public.redemption_status as enum ('pending_delivery', 'redeemed', 'cancelled');
  end if;
end
$$;

-- ---------------------------------------------------------------------
-- Perfiles y roles
-- ---------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '',
  email text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_email_not_blank check (length(btrim(email)) > 0)
);

create index profiles_email_lower_idx on public.profiles (lower(email));
create index profiles_full_name_lower_idx on public.profiles (lower(full_name));

comment on table public.profiles is
  'Perfil público mínimo asociado a auth.users. Se crea exclusivamente por trigger.';

create table public.user_roles (
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.app_role not null,
  granted_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create index user_roles_role_idx on public.user_roles (role);

comment on table public.user_roles is
  'Roles de aplicación. Solo se modifican mediante RPC administrativas auditadas.';

-- ---------------------------------------------------------------------
-- Configuración del programa (fila única)
-- ---------------------------------------------------------------------
create table public.program_settings (
  id boolean primary key default true,
  cop_per_point_unit integer not null default 1000,
  min_purchase_amount integer not null default 0,
  max_points_per_purchase integer not null default 500,
  qr_expiry_hours integer not null default 24,
  points_expiry_days integer,
  history_page_size integer not null default 10,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null,
  constraint program_settings_singleton check (id),
  constraint program_settings_point_unit check (cop_per_point_unit between 100 and 1000000),
  constraint program_settings_min_purchase check (min_purchase_amount between 0 and 50000000),
  constraint program_settings_max_points check (max_points_per_purchase between 1 and 1000000),
  constraint program_settings_qr_expiry check (qr_expiry_hours between 1 and 168),
  constraint program_settings_points_expiry check (
    points_expiry_days is null or points_expiry_days between 1 and 3650
  ),
  constraint program_settings_page_size check (history_page_size between 1 and 100)
);

insert into public.program_settings (id) values (true) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- Compras
-- ---------------------------------------------------------------------
create table public.purchases (
  id uuid primary key default extensions.gen_random_uuid(),
  amount_cop integer not null,
  registrar_id uuid not null references public.profiles (id) on delete restrict,
  token_hash text not null,
  status public.purchase_status not null default 'pending_claim',
  claimed_by uuid references public.profiles (id) on delete restrict,
  claimed_at timestamptz,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete set null,
  cancellation_reason text,
  points_awarded integer not null default 0,
  settings_snapshot jsonb not null default '{}'::jsonb,
  constraint purchases_amount_positive check (amount_cop > 0 and amount_cop <= 50000000),
  constraint purchases_token_hash_format check (token_hash ~ '^[a-f0-9]{64}$'),
  constraint purchases_points_nonnegative check (points_awarded >= 0),
  constraint purchases_expiry_after_creation check (expires_at > created_at),
  constraint purchases_claim_consistency check (
    (status = 'claimed' and claimed_by is not null and claimed_at is not null)
    or (status <> 'claimed' and claimed_by is null and claimed_at is null)
  ),
  constraint purchases_cancel_consistency check (
    (status = 'cancelled' and cancelled_at is not null)
    or (status <> 'cancelled' and cancelled_at is null)
  ),
  constraint purchases_token_hash_unique unique (token_hash)
);

create index purchases_claimed_by_idx on public.purchases (claimed_by, claimed_at desc);
create index purchases_status_idx on public.purchases (status, expires_at);
create index purchases_registrar_idx on public.purchases (registrar_id, created_at desc);

comment on column public.purchases.token_hash is
  'SHA-256 hexadecimal del token del QR. El token en claro nunca se almacena.';
comment on column public.purchases.settings_snapshot is
  'Reglas vigentes al crear la compra. Los cambios de configuración no alteran compras anteriores.';

-- ---------------------------------------------------------------------
-- Recompensas y canjes
-- ---------------------------------------------------------------------
create table public.rewards (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null,
  description text not null default '',
  image_url text,
  points_cost integer not null,
  is_active boolean not null default true,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint rewards_name_length check (length(btrim(name)) between 2 and 120),
  constraint rewards_points_positive check (points_cost > 0 and points_cost <= 1000000),
  constraint rewards_image_url_format check (
    image_url is null or image_url ~ '^https?://'
  )
);

create unique index rewards_name_lower_unique on public.rewards (lower(btrim(name)));

create table public.redemptions (
  id uuid primary key default extensions.gen_random_uuid(),
  customer_id uuid not null references public.profiles (id) on delete restrict,
  reward_id uuid not null references public.rewards (id) on delete restrict,
  reward_name text not null,
  points_spent integer not null,
  code text not null,
  status public.redemption_status not null default 'pending_delivery',
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  delivered_by uuid references public.profiles (id) on delete set null,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete set null,
  cancellation_reason text,
  constraint redemptions_points_positive check (points_spent > 0),
  constraint redemptions_code_format check (code ~ '^[A-Z0-9]{6,32}$'),
  constraint redemptions_code_unique unique (code),
  constraint redemptions_idempotency_unique unique (customer_id, idempotency_key),
  constraint redemptions_delivery_consistency check (
    (status = 'redeemed' and delivered_at is not null and delivered_by is not null)
    or (status <> 'redeemed' and delivered_at is null and delivered_by is null)
  ),
  constraint redemptions_cancel_consistency check (
    (status = 'cancelled' and cancelled_at is not null)
    or (status <> 'cancelled' and cancelled_at is null)
  ),
  constraint redemptions_reason_length check (
    cancellation_reason is null or length(cancellation_reason) <= 300
  )
);

create index redemptions_customer_idx on public.redemptions (customer_id, created_at desc);
create index redemptions_status_idx on public.redemptions (status, created_at);
create index redemptions_reward_idx on public.redemptions (reward_id);

comment on column public.redemptions.code is
  'Código de canje que el cliente muestra al registrador. Único e irreversible una vez entregado.';

-- ---------------------------------------------------------------------
-- Libro mayor de puntos (inmutable)
-- ---------------------------------------------------------------------
create table public.points_ledger (
  id uuid primary key default extensions.gen_random_uuid(),
  customer_id uuid not null references public.profiles (id) on delete restrict,
  movement_type public.points_movement_type not null,
  points integer not null,
  purchase_id uuid references public.purchases (id) on delete restrict,
  redemption_id uuid references public.redemptions (id) on delete restrict,
  reason text,
  idempotency_key text not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint points_ledger_nonzero check (points <> 0),
  constraint points_ledger_idempotency_unique unique (idempotency_key),
  constraint points_ledger_reason_length check (reason is null or length(reason) <= 300),
  constraint points_ledger_type_sign check (
    (movement_type = 'purchase_credit' and points > 0 and purchase_id is not null and redemption_id is null)
    or (movement_type = 'redemption_debit' and points < 0 and redemption_id is not null and purchase_id is null)
    or (movement_type = 'redemption_refund' and points > 0 and redemption_id is not null and purchase_id is null)
    or (movement_type = 'expiry_debit' and points < 0 and purchase_id is null and redemption_id is null)
    or (movement_type = 'admin_adjustment' and purchase_id is null and redemption_id is null)
  )
);

create unique index points_ledger_one_credit_per_purchase
  on public.points_ledger (purchase_id)
  where movement_type = 'purchase_credit';

create unique index points_ledger_one_debit_per_redemption
  on public.points_ledger (redemption_id)
  where movement_type = 'redemption_debit';

create unique index points_ledger_one_refund_per_redemption
  on public.points_ledger (redemption_id)
  where movement_type = 'redemption_refund';

create index points_ledger_customer_idx on public.points_ledger (customer_id, created_at desc);

comment on table public.points_ledger is
  'Historial inmutable. El saldo es la suma de movimientos, nunca un campo editable.';

-- ---------------------------------------------------------------------
-- Auditoría, historial de configuración y límites de frecuencia
-- ---------------------------------------------------------------------
create table public.audit_log (
  id uuid primary key default extensions.gen_random_uuid(),
  actor_id uuid references public.profiles (id) on delete set null,
  actor_email text,
  operation text not null,
  entity_type text not null,
  entity_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index audit_log_created_idx on public.audit_log (created_at desc);
create index audit_log_entity_idx on public.audit_log (entity_type, entity_id);

create table public.config_history (
  id bigint generated always as identity primary key,
  changed_by uuid references public.profiles (id) on delete set null,
  before_value jsonb not null,
  after_value jsonb not null,
  created_at timestamptz not null default now()
);

create table private.rate_limits (
  bucket text primary key,
  window_start timestamptz not null default now(),
  count integer not null default 0
);

-- ---------------------------------------------------------------------
-- Funciones internas de mantenimiento
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

create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function private.touch_updated_at();

create trigger rewards_touch_updated_at
  before update on public.rewards
  for each row execute function private.touch_updated_at();

create trigger program_settings_touch_updated_at
  before update on public.program_settings
  for each row execute function private.touch_updated_at();

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
      ''
    ),
    coalesce(new.email, '')
  )
  on conflict (id) do update
    set email = excluded.email,
        full_name = case
          when public.profiles.full_name = '' then excluded.full_name
          else public.profiles.full_name
        end;

  -- Toda cuenta autenticada es cliente. Los roles privilegiados se conceden
  -- únicamente con una RPC administrativa auditada.
  insert into public.user_roles (user_id, role)
  values (new.id, 'customer')
  on conflict do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

create or replace function private.prevent_ledger_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'points_ledger_is_immutable'
    using detail = 'El historial de puntos no permite actualizaciones ni eliminaciones.';
end;
$$;

create trigger points_ledger_immutable
  before update or delete on public.points_ledger
  for each row execute function private.prevent_ledger_mutation();

create or replace function private.assert_nonnegative_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_balance bigint;
begin
  select coalesce(sum(points), 0)
    into v_balance
    from public.points_ledger
   where customer_id = new.customer_id;

  if v_balance < 0 then
    raise exception 'negative_points_balance'
      using detail = 'La operación dejaría al cliente con saldo negativo.';
  end if;

  return null;
end;
$$;

create constraint trigger points_ledger_nonnegative
  after insert on public.points_ledger
  deferrable initially deferred
  for each row execute function private.assert_nonnegative_balance();

create or replace function private.log_status_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status is distinct from old.status then
    insert into public.audit_log (actor_id, actor_email, operation, entity_type, entity_id, metadata)
    values (
      auth.uid(),
      (select email from public.profiles where id = auth.uid()),
      tg_table_name || '.status_changed',
      tg_table_name,
      new.id::text,
      jsonb_build_object('from', old.status, 'to', new.status)
    );
  end if;
  return new;
end;
$$;

create trigger purchases_log_status_change
  after update of status on public.purchases
  for each row execute function private.log_status_change();

create trigger redemptions_log_status_change
  after update of status on public.redemptions
  for each row execute function private.log_status_change();
