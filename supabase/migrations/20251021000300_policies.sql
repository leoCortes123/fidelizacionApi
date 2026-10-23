-- =====================================================================
-- Row Level Security y privilegios
-- Principio: el cliente solo lee lo suyo; el personal lee la operación;
-- toda escritura pasa por RPC SECURITY DEFINER con autorización explícita.
-- =====================================================================

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.program_settings enable row level security;
alter table public.purchases enable row level security;
alter table public.rewards enable row level security;
alter table public.redemptions enable row level security;
alter table public.points_ledger enable row level security;
alter table public.audit_log enable row level security;
alter table public.config_history enable row level security;

-- Perfiles -------------------------------------------------------------
create policy profiles_select_own_or_staff
  on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_staff());

create policy profiles_update_own
  on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Roles ----------------------------------------------------------------
create policy user_roles_select_own_or_admin
  on public.user_roles for select to authenticated
  using (user_id = auth.uid() or public.has_role('admin'));

-- Configuración --------------------------------------------------------
create policy program_settings_read_authenticated
  on public.program_settings for select to authenticated
  using (true);

-- Compras --------------------------------------------------------------
create policy purchases_select_own_or_staff
  on public.purchases for select to authenticated
  using (claimed_by = auth.uid() or public.is_staff());

-- Recompensas ----------------------------------------------------------
create policy rewards_select_active_or_staff
  on public.rewards for select to authenticated
  using (is_active or public.is_staff());

-- Canjes ---------------------------------------------------------------
create policy redemptions_select_own_or_staff
  on public.redemptions for select to authenticated
  using (customer_id = auth.uid() or public.is_staff());

-- Libro de puntos ------------------------------------------------------
create policy points_ledger_select_own_or_staff
  on public.points_ledger for select to authenticated
  using (customer_id = auth.uid() or public.is_staff());

-- Auditoría ------------------------------------------------------------
create policy audit_log_select_admin
  on public.audit_log for select to authenticated
  using (public.has_role('admin'));

create policy config_history_select_admin
  on public.config_history for select to authenticated
  using (public.has_role('admin'));

-- ---------------------------------------------------------------------
-- Privilegios de tabla: lectura explícita; sin INSERT/UPDATE/DELETE
-- directos (las escrituras se hacen mediante RPC).
-- ---------------------------------------------------------------------
revoke all on public.profiles, public.user_roles, public.program_settings,
  public.purchases, public.rewards, public.redemptions, public.points_ledger,
  public.audit_log, public.config_history from anon, authenticated;

grant select on public.profiles, public.user_roles, public.program_settings,
  public.purchases, public.rewards, public.redemptions, public.points_ledger
  to authenticated;

-- El cliente solo puede editar su nombre visible, nunca su correo ni su id.
grant update (full_name) on public.profiles to authenticated;

grant select on public.audit_log, public.config_history to authenticated;

revoke all on schema private from public;
revoke all on all tables in schema private from public;

-- ---------------------------------------------------------------------
-- Privilegios de funciones: denegar por defecto y habilitar solo las RPC
-- que el cliente autenticado necesita.
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema private from public;

grant execute on function public.has_role(public.app_role) to authenticated;
grant execute on function public.is_staff() to authenticated;

grant execute on function public.get_my_roles() to authenticated;
grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.get_program_settings() to authenticated;
grant execute on function public.get_my_dashboard() to authenticated;
grant execute on function public.list_my_purchases(integer, integer) to authenticated;
grant execute on function public.list_active_rewards() to authenticated;
grant execute on function public.list_my_redemptions() to authenticated;

grant execute on function public.claim_purchase(text) to authenticated;
grant execute on function public.customer_redeem_reward(uuid, text) to authenticated;

grant execute on function public.create_purchase(integer) to authenticated;
grant execute on function public.staff_cancel_purchase(uuid, text) to authenticated;
grant execute on function public.staff_list_customers(text, integer, integer, text, text) to authenticated;
grant execute on function public.staff_get_customer(uuid) to authenticated;
grant execute on function public.staff_list_purchases(integer, integer, text) to authenticated;
grant execute on function public.staff_list_redemptions(text, integer) to authenticated;
grant execute on function public.staff_lookup_redemption(text) to authenticated;
grant execute on function public.staff_confirm_redemption(text) to authenticated;
grant execute on function public.staff_cancel_redemption(uuid, text) to authenticated;

grant execute on function public.admin_get_settings() to authenticated;
grant execute on function public.admin_update_settings(jsonb) to authenticated;
grant execute on function public.admin_list_rewards() to authenticated;
grant execute on function public.admin_upsert_reward(uuid, text, text, integer, text, boolean) to authenticated;
grant execute on function public.admin_list_staff() to authenticated;
grant execute on function public.admin_search_profiles(text) to authenticated;
grant execute on function public.admin_grant_role(uuid, public.app_role) to authenticated;
grant execute on function public.admin_revoke_role(uuid, public.app_role) to authenticated;
grant execute on function public.admin_get_audit_log(integer, integer) to authenticated;
grant execute on function public.admin_get_config_history(integer) to authenticated;
grant execute on function public.admin_expire_points() to authenticated;
