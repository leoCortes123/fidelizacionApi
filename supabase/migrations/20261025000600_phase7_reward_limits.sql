-- =====================================================================
-- Fase 7 — Límites de canje y validación de descuentos
--
-- Cierra dos brechas detectadas al preparar las pruebas de aceptación:
--   1. `loyalty_reward_upsert` guardaba `max_redemptions_per_period`,
--      `redemption_period_days` y `total_redemption_limit`, pero
--      `reward_request_redemption` solo aplicaba el límite por cliente.
--   2. El tipo de descuento no se validaba: se podía crear un descuento
--      porcentual sin porcentaje o un descuento fijo sin importe.
--
-- Las migraciones son aditivas: no se alteran filas existentes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Recompensas: coherencia entre tipo y descuento, y periodo completo
-- ---------------------------------------------------------------------
create or replace function public.loyalty_reward_upsert(
  p_business_id uuid,
  p_type public.loyalty_reward_type,
  p_name text,
  p_points_required integer,
  p_id uuid default null,
  p_product_id uuid default null,
  p_description text default '',
  p_min_purchase_amount integer default 0,
  p_max_discount_amount integer default null,
  p_discount_percentage numeric default null,
  p_valid_from timestamptz default null,
  p_valid_until timestamptz default null,
  p_max_redemptions_per_customer integer default null,
  p_max_redemptions_per_period integer default null,
  p_redemption_period_days integer default null,
  p_total_redemption_limit integer default null,
  p_is_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_price_cop integer;
  v_cost_cop integer;
  v_discount_percentage numeric := p_discount_percentage;
  v_max_discount_amount integer := p_max_discount_amount;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  if length(btrim(coalesce(p_name, ''))) < 2 then
    raise exception 'invalid_reward_name';
  end if;
  if p_points_required <= 0 or p_points_required > 10000000 then
    raise exception 'invalid_reward_points';
  end if;
  if p_min_purchase_amount < 0 then
    raise exception 'invalid_min_purchase';
  end if;
  if p_valid_from is not null and p_valid_until is not null and p_valid_until <= p_valid_from then
    raise exception 'invalid_reward_validity';
  end if;
  if p_max_redemptions_per_period is not null then
    if p_max_redemptions_per_period < 1 then
      raise exception 'invalid_redemption_limit';
    end if;
    if p_redemption_period_days is null
       or p_redemption_period_days < 1
       or p_redemption_period_days > 3650 then
      raise exception 'invalid_redemption_period';
    end if;
  end if;
  if p_max_redemptions_per_customer is not null and p_max_redemptions_per_customer < 1 then
    raise exception 'invalid_redemption_limit';
  end if;
  if p_total_redemption_limit is not null and p_total_redemption_limit < 1 then
    raise exception 'invalid_redemption_limit';
  end if;

  -- Solo los descuentos conservan importe/porcentaje; el resto los limpia.
  if p_type = 'percentage_discount' then
    if p_discount_percentage is null or p_discount_percentage <= 0 or p_discount_percentage > 100 then
      raise exception 'invalid_discount_percentage';
    end if;
    v_max_discount_amount := p_max_discount_amount;
  elsif p_type = 'fixed_discount' then
    if p_max_discount_amount is null or p_max_discount_amount <= 0 then
      raise exception 'invalid_max_discount';
    end if;
    v_discount_percentage := null;
  else
    v_discount_percentage := null;
    v_max_discount_amount := null;
  end if;

  if v_max_discount_amount is not null and v_max_discount_amount < 0 then
    raise exception 'invalid_max_discount';
  end if;
  -- Un descuento no puede superar el mínimo de compra que lo habilita;
  -- si no hay mínimo, tampoco hay tope que comparar.
  if v_max_discount_amount is not null
     and p_min_purchase_amount > 0
     and v_max_discount_amount > p_min_purchase_amount then
    raise exception 'discount_exceeds_min_purchase';
  end if;

  if p_type = 'free_product' then
    if p_product_id is null then
      raise exception 'free_product_requires_product';
    end if;
    select price_cop, cost_cop into v_price_cop, v_cost_cop
      from public.products
     where id = p_product_id and business_id = p_business_id;
    if not found then
      raise exception 'product_not_found';
    end if;
  else
    v_price_cop := null;
    v_cost_cop := null;
  end if;

  if p_id is null then
    insert into public.loyalty_rewards (
      business_id, product_id, type, name, description, points_required,
      min_purchase_amount, max_discount_amount, discount_percentage,
      product_price_cop, product_cost_cop, valid_from, valid_until,
      max_redemptions_per_customer, max_redemptions_per_period,
      redemption_period_days, total_redemption_limit, is_active, created_by
    ) values (
      p_business_id, p_product_id, p_type, btrim(p_name),
      btrim(coalesce(p_description, '')), p_points_required,
      p_min_purchase_amount, v_max_discount_amount, v_discount_percentage,
      v_price_cop, v_cost_cop, p_valid_from, p_valid_until,
      p_max_redemptions_per_customer, p_max_redemptions_per_period,
      case when p_max_redemptions_per_period is null then null else p_redemption_period_days end,
      p_total_redemption_limit, p_is_active, v_uid
    )
    returning id into v_id;
  else
    update public.loyalty_rewards
       set product_id = p_product_id,
           type = p_type,
           name = btrim(p_name),
           description = btrim(coalesce(p_description, '')),
           points_required = p_points_required,
           min_purchase_amount = p_min_purchase_amount,
           max_discount_amount = v_max_discount_amount,
           discount_percentage = v_discount_percentage,
           product_price_cop = v_price_cop,
           product_cost_cop = v_cost_cop,
           valid_from = p_valid_from,
           valid_until = p_valid_until,
           max_redemptions_per_customer = p_max_redemptions_per_customer,
           max_redemptions_per_period = p_max_redemptions_per_period,
           redemption_period_days = case
             when p_max_redemptions_per_period is null then null
             else p_redemption_period_days
           end,
           total_redemption_limit = p_total_redemption_limit,
           is_active = p_is_active,
           updated_at = now()
     where id = p_id and business_id = p_business_id
    returning id into v_id;
    if v_id is null then raise exception 'reward_not_found'; end if;
  end if;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    case when p_id is null then 'reward.created' else 'reward.updated' end,
    'loyalty_reward',
    v_id::text,
    jsonb_build_object(
      'name', p_name, 'type', p_type, 'points_required', p_points_required,
      'product_id', p_product_id, 'is_active', p_is_active
    )
  );

  return (select to_jsonb(r) from public.loyalty_rewards r where r.id = v_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Solicitud de redención: límites por periodo y total
-- ---------------------------------------------------------------------
create or replace function public.reward_request_redemption(
  p_business_id uuid,
  p_reward_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_reward public.loyalty_rewards;
  v_account public.loyalty_point_accounts;
  v_membership public.business_memberships;
  v_existing public.loyalty_redemptions;
  v_redemption_id uuid;
  v_code text;
  v_token text;
  v_token_hash text;
  v_program public.loyalty_programs;
  v_expires_at timestamptz;
  v_balance bigint;
  v_count integer;
  v_now timestamptz := now();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,64}$' then
    raise exception 'invalid_idempotency_key';
  end if;

  v_membership := public.business_current_membership(p_business_id);
  if v_membership.user_id <> v_uid then
    raise exception 'forbidden';
  end if;

  select * into v_account
    from public.loyalty_point_accounts
   where business_id = p_business_id and customer_id = v_uid;

  if not found then
    raise exception 'account_not_found';
  end if;

  -- Idempotencia: devolver la misma solicitud sin volver a reservar.
  select * into v_existing
    from public.loyalty_redemptions
   where account_id = v_account.id and idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'redemption_id', v_existing.id,
      'reward_name', v_existing.reward_name,
      'points_spent', v_existing.points_spent,
      'status', v_existing.status,
      'code', v_existing.code,
      'created_at', v_existing.created_at,
      'duplicate', true
    );
  end if;

  select * into v_reward
    from public.loyalty_rewards
   where id = p_reward_id and business_id = p_business_id
   for share;

  if not found or not v_reward.is_active then
    raise exception 'reward_unavailable';
  end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found or not v_program.is_active then
    raise exception 'program_not_active';
  end if;

  -- Vigencia de la recompensa.
  if v_reward.valid_from is not null and v_reward.valid_from > v_now then
    raise exception 'reward_not_yet_valid';
  end if;
  if v_reward.valid_until is not null and v_reward.valid_until <= v_now then
    raise exception 'reward_expired';
  end if;

  -- Límite por cliente (histórico completo).
  if v_reward.max_redemptions_per_customer is not null then
    select count(*) into v_count
      from public.loyalty_redemptions r
      join public.loyalty_point_accounts a on a.id = r.account_id
     where a.business_id = p_business_id
       and a.customer_id = v_uid
       and r.reward_id = p_reward_id
       and r.status in ('pending', 'approved', 'delivered');
    if v_count >= v_reward.max_redemptions_per_customer then
      raise exception 'reward_customer_limit_reached';
    end if;
  end if;

  -- Límite por periodo móvil (días configurados).
  if v_reward.max_redemptions_per_period is not null
     and v_reward.redemption_period_days is not null then
    select count(*) into v_count
      from public.loyalty_redemptions r
      join public.loyalty_point_accounts a on a.id = r.account_id
     where a.business_id = p_business_id
       and a.customer_id = v_uid
       and r.reward_id = p_reward_id
       and r.status in ('pending', 'approved', 'delivered')
       and r.created_at >= v_now - make_interval(days => v_reward.redemption_period_days);
    if v_count >= v_reward.max_redemptions_per_period then
      raise exception 'reward_period_limit_reached';
    end if;
  end if;

  -- Límite total del negocio para esta recompensa.
  if v_reward.total_redemption_limit is not null then
    select count(*) into v_count
      from public.loyalty_redemptions r
     where r.business_id = p_business_id
       and r.reward_id = p_reward_id
       and r.status in ('pending', 'approved', 'delivered');
    if v_count >= v_reward.total_redemption_limit then
      raise exception 'reward_total_limit_reached';
    end if;
  end if;

  select coalesce(sum(points), 0) into v_balance
    from public.loyalty_point_transactions
   where account_id = v_account.id;

  if v_balance < v_reward.points_required then
    raise exception 'insufficient_points'
      using detail = format('Tienes %s puntos y se requieren %s.', v_balance, v_reward.points_required);
  end if;

  -- Reservar puntos (débito pendiente).
  perform public.loyalty_transaction_post(
    p_business_id, v_account.id, 'redemption_debit', -v_reward.points_required,
    'redemption', null,
    format('Reserva para recompensa %s', v_reward.name),
    'redemption:' || gen_random_uuid()::text || ':reserve', v_uid
  );

  loop
    v_code := 'TP' || upper(encode(extensions.gen_random_bytes(6), 'hex'));
    exit when not exists (select 1 from public.loyalty_redemptions where code = v_code);
  end loop;

  insert into public.loyalty_redemptions (
    business_id, account_id, reward_id, reward_name, reward_type,
    points_spent, code, status, idempotency_key, created_by, created_at
  ) values (
    p_business_id, v_account.id, v_reward.id, v_reward.name, v_reward.type,
    v_reward.points_required, v_code, 'pending', p_idempotency_key, v_uid, v_now
  )
  returning id into v_redemption_id;

  -- Generar token QR aleatorio vinculado al negocio y la solicitud.
  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  v_expires_at := v_now + make_interval(hours => coalesce(v_program.qr_expiry_hours, 24));

  insert into public.loyalty_redemption_tokens (
    business_id, redemption_id, token_hash, expires_at
  ) values (
    p_business_id, v_redemption_id, v_token_hash, v_expires_at
  );

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.requested',
    'loyalty_redemption',
    v_redemption_id::text,
    jsonb_build_object(
      'reward_id', v_reward.id,
      'reward_name', v_reward.name,
      'points_spent', v_reward.points_required,
      'expires_at', v_expires_at
    )
  );

  return jsonb_build_object(
    'redemption_id', v_redemption_id,
    'reward_name', v_reward.name,
    'points_spent', v_reward.points_required,
    'code', v_code,
    'status', 'pending',
    'token', v_token,
    'expires_at', v_expires_at,
    'duplicate', false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Permisos (mismas firmas: los grants existentes se conservan)
-- ---------------------------------------------------------------------
revoke all on function public.loyalty_reward_upsert(
  uuid, public.loyalty_reward_type, text, integer, uuid, uuid, text, integer,
  integer, numeric, timestamptz, timestamptz, integer, integer, integer, integer, boolean
) from public;
grant execute on function public.loyalty_reward_upsert(
  uuid, public.loyalty_reward_type, text, integer, uuid, uuid, text, integer,
  integer, numeric, timestamptz, timestamptz, integer, integer, integer, integer, boolean
) to authenticated;

revoke all on function public.reward_request_redemption(uuid, uuid, text) from public;
grant execute on function public.reward_request_redemption(uuid, uuid, text) to authenticated;
