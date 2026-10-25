-- =====================================================================
-- Row Level Security y privilegios: aislamiento por negocio
-- Principio: cada entidad lleva business_id; el cliente solo lee lo suyo;
-- el personal del negocio lee lo de su negocio; las escrituras pasan por
-- RPC SECURITY DEFINER que valida el negocio desde auth.uid().
-- =====================================================================

alter table public.businesses enable row level security;
alter table public.business_memberships enable row level security;
alter table public.products enable row level security;
alter table public.loyalty_programs enable row level security;
alter table public.loyalty_rewards enable row level security;
alter table public.loyalty_point_accounts enable row level security;
alter table public.loyalty_point_transactions enable row level security;
alter table public.loyalty_redemptions enable row level security;
alter table public.loyalty_redemption_tokens enable row level security;
alter table public.business_economic_profiles enable row level security;
alter table public.loyalty_purchase_events enable row level security;
alter table public.business_audit_logs enable row level security;

-- Negocios: el dueño/creador y los miembros ven su negocio.
create policy businesses_select_member
  on public.businesses for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = businesses.id and m.user_id = auth.uid()
    )
    or id = (select created_by from public.businesses b where b.id = businesses.id)
  );

-- Membresías: el propio usuario ve las suyas; admin/encargado del negocio ve las del negocio.
create policy business_memberships_select_own_or_staff
  on public.business_memberships for select to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.business_memberships m
       where m.business_id = business_memberships.business_id
         and m.user_id = auth.uid()
         and m.role in ('admin', 'encargado')
    )
  );

-- Productos: miembros del negocio ven los suyos.
create policy products_select_member
  on public.products for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = products.business_id and m.user_id = auth.uid()
    )
  );

-- Programa de puntos: miembros del negocio.
create policy loyalty_programs_select_member
  on public.loyalty_programs for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = loyalty_programs.business_id and m.user_id = auth.uid()
    )
  );

-- Recompensas: miembros del negocio (activas para cliente, todas para staff).
create policy loyalty_rewards_select_member
  on public.loyalty_rewards for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = loyalty_rewards.business_id and m.user_id = auth.uid()
    )
  );

-- Cuenta de puntos: el propio cliente ve la suya; staff del negocio ve todas.
create policy loyalty_point_accounts_select_own_or_staff
  on public.loyalty_point_accounts for select to authenticated
  using (
    customer_id = auth.uid()
    or exists (
      select 1 from public.business_memberships m
       where m.business_id = loyalty_point_accounts.business_id
         and m.user_id = auth.uid()
         and m.role in ('admin', 'encargado')
    )
  );

-- Libro de transacciones: el propio cliente ve las suyas; staff del negocio ve todas.
create policy loyalty_point_transactions_select_own_or_staff
  on public.loyalty_point_transactions for select to authenticated
  using (
    exists (
      select 1 from public.loyalty_point_accounts a
       join public.business_memberships m on m.business_id = a.business_id
      where a.id = loyalty_point_transactions.account_id
        and m.user_id = auth.uid()
    )
  );

-- Redenciones: el propio cliente ve las suyas; staff del negocio ve todas.
create policy loyalty_redemptions_select_own_or_staff
  on public.loyalty_redemptions for select to authenticated
  using (
    exists (
      select 1 from public.loyalty_point_accounts a
       join public.business_memberships m on m.business_id = a.business_id
      where a.id = loyalty_redemptions.account_id
        and m.user_id = auth.uid()
    )
  );

-- Tokens QR: solo staff del negocio que los creó.
create policy loyalty_redemption_tokens_select_staff
  on public.loyalty_redemption_tokens for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = loyalty_redemption_tokens.business_id
         and m.user_id = auth.uid()
         and m.role in ('admin', 'encargado')
    )
  );

-- Perfil económico: miembros del negocio.
create policy business_economic_profiles_select_member
  on public.business_economic_profiles for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = business_economic_profiles.business_id and m.user_id = auth.uid()
    )
  );

-- Eventos de compra: miembros del negocio.
create policy loyalty_purchase_events_select_member
  on public.loyalty_purchase_events for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = loyalty_purchase_events.business_id and m.user_id = auth.uid()
    )
  );

-- Auditoría del negocio: miembros del negocio.
create policy business_audit_logs_select_member
  on public.business_audit_logs for select to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
       where m.business_id = business_audit_logs.business_id and m.user_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------
-- Privilegios de tabla: lectura explícita; sin escrituras directas.
-- ---------------------------------------------------------------------
revoke all on public.businesses, public.business_memberships, public.products,
  public.loyalty_programs, public.loyalty_rewards, public.loyalty_point_accounts,
  public.loyalty_point_transactions, public.loyalty_redemptions,
  public.loyalty_redemption_tokens, public.business_economic_profiles,
  public.loyalty_purchase_events, public.business_audit_logs
  from anon, authenticated;

grant select on public.businesses, public.business_memberships, public.products,
  public.loyalty_programs, public.loyalty_rewards, public.loyalty_point_accounts,
  public.loyalty_point_transactions, public.loyalty_redemptions,
  public.loyalty_redemption_tokens, public.business_economic_profiles,
  public.loyalty_purchase_events, public.business_audit_logs
  to authenticated;

-- ---------------------------------------------------------------------
-- Privilegios de funciones: conceder EXECUTE solo a las RPC necesarias.
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public;

-- Cliente
grant execute on function public.business_current_membership(uuid) to authenticated;
grant execute on function public.require_business_role(uuid, public.business_role[]) to authenticated;
grant execute on function public.business_register(text, text, text) to authenticated;
grant execute on function public.loyalty_account_ensure(uuid, uuid) to authenticated;
grant execute on function public.loyalty_account_balance(uuid, uuid) to authenticated;
grant execute on function public.loyalty_account_transactions(uuid, uuid, integer, integer) to authenticated;
grant execute on function public.reward_request_redemption(uuid, uuid, text) to authenticated;
grant execute on function public.loyalty_rewards_available(uuid, uuid) to authenticated;
grant execute on function public.products_list(uuid, boolean) to authenticated;
grant execute on function public.loyalty_rewards_list(uuid, boolean) to authenticated;

-- Staff (admin/encargado) del negocio
grant execute on function public.business_membership_create(uuid, uuid, public.business_role, boolean) to authenticated;
grant execute on function public.business_membership_update(uuid, uuid, boolean) to authenticated;
grant execute on function public.business_memberships_list(uuid) to authenticated;
grant execute on function public.loyalty_program_configure(
  uuid, integer, integer, integer, numeric, integer, integer, integer, integer
) to authenticated;
grant execute on function public.product_upsert(
  uuid, integer, text, uuid, text, integer, boolean
) to authenticated;
grant execute on function public.loyalty_reward_upsert(
  uuid, public.loyalty_reward_type, text, integer, uuid, uuid, text, integer, integer, numeric, timestamptz, timestamptz, integer, integer, integer, integer, boolean
) to authenticated;
grant execute on function public.redemption_token_validate(uuid, text) to authenticated;
grant execute on function public.redemption_approve(uuid, uuid, boolean) to authenticated;
grant execute on function public.redemption_deliver(uuid, uuid) to authenticated;
grant execute on function public.redemption_cancel(uuid, uuid, text) to authenticated;
grant execute on function public.loyalty_redemptions_list(uuid, public.redemption_request_status, integer, integer) to authenticated;

-- Admin del negocio
grant execute on function public.points_accrue_from_purchase(
  uuid, uuid, uuid, integer, integer, text, uuid, text
) to authenticated;
grant execute on function public.points_reverse_purchase(uuid, uuid, uuid, text, uuid) to authenticated;
grant execute on function public.points_grant_bonus(
  uuid, uuid, text, integer, text, text, uuid
) to authenticated;
grant execute on function public.business_economic_profile_upsert(
  uuid, integer, integer, integer, numeric, integer, integer, jsonb
) to authenticated;
grant execute on function public.business_dashboard_economic(uuid) to authenticated;
grant execute on function public.business_audit_log_list(uuid, integer, integer) to authenticated;
