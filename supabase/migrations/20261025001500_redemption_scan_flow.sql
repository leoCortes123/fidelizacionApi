-- =====================================================================
-- Loopoint F6 — Canje escaneado por QR (M5)
--
-- El QR del cliente deja de ser solo un token: contiene una URL
-- `/scan/<token>`. Esta migración añade las RPC que resuelven el negocio
-- desde el token (sin que el navegador envíe `business_id`) y que
-- confirman la entrega en un único paso atómico.
--
-- Reglas:
--   * El servidor sigue siendo la autoridad de negocio, permisos y saldo.
--   * El token es una credencial portadora: se consume al entregar.
--   * Todo escaneo válido queda auditado con su origen.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Origen de la solicitud en el listado del negocio.
--    `manual`  → el cliente la creó desde su cuenta y el negocio la
--                aprueba desde la lista.
--    `qr_scan` → el negocio escaneó el QR y entregó en el mismo acto.
-- ---------------------------------------------------------------------
alter table public.loyalty_redemptions
  add column if not exists origin text not null default 'manual';

do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'loyalty_redemptions_origin_check'
  ) then
    alter table public.loyalty_redemptions
      add constraint loyalty_redemptions_origin_check
      check (origin in ('manual', 'qr_scan'));
  end if;
end
$$;

comment on column public.loyalty_redemptions.origin is
  'Canal por el que la solicitud llegó al negocio: manual (lista) o qr_scan (QR escaneado).';

-- ---------------------------------------------------------------------
-- 1. Contexto del token sin `business_id`.
--    Devuelve lo justo para mostrar la pantalla /scan/:token.
-- ---------------------------------------------------------------------
create or replace function public.redemption_token_context(
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_token public.loyalty_redemption_tokens;
  v_redemption public.loyalty_redemptions;
  v_membership public.business_memberships;
  v_business public.businesses;
  v_nickname text;
  v_customer_id uuid;
  v_can_redeem boolean := false;
  v_reason text;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  -- Límite por usuario: evita probar tokens a ciegas.
  perform private.consume_rate_limit('redemption_scan_context:' || v_uid::text, 60, 60);

  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');

  select * into v_token
    from public.loyalty_redemption_tokens
   where token_hash = v_hash;

  if not found then
    raise exception 'invalid_token';
  end if;

  -- El negocio sale del token, no del navegador.
  v_membership := public.business_current_membership(v_token.business_id);

  if v_membership.role not in ('admin', 'encargado') then
    raise exception 'forbidden';
  end if;
  if v_membership.role = 'encargado' and not v_membership.can_approve_redemptions then
    raise exception 'forbidden';
  end if;

  select * into v_redemption
    from public.loyalty_redemptions
   where id = v_token.redemption_id
     and business_id = v_token.business_id;

  if not found then
    raise exception 'redemption_not_found';
  end if;

  select * into v_business
    from public.businesses
   where id = v_redemption.business_id;

  select a.customer_id, p.nickname
    into v_customer_id, v_nickname
    from public.loyalty_point_accounts a
    join public.profiles p on p.id = a.customer_id
   where a.id = v_redemption.account_id;

  if v_redemption.status = 'delivered' then
    v_reason := 'redemption_already_delivered';
  elsif v_redemption.status = 'cancelled' then
    v_reason := 'redemption_cancelled';
  elsif v_redemption.status = 'expired' then
    v_reason := 'redemption_expired';
  elsif v_redemption.status <> 'pending' then
    v_reason := 'redemption_not_pending';
  elsif v_token.consumed_at is not null then
    v_reason := 'token_already_consumed';
  elsif v_token.expires_at <= v_now then
    v_reason := 'token_expired';
  else
    v_can_redeem := true;
  end if;

  return jsonb_build_object(
    'business_id', v_redemption.business_id,
    'business_name', v_business.name,
    'business_slug', v_business.slug,
    'business_logo_url', v_business.logo_url,
    'redemption_id', v_redemption.id,
    'code', v_redemption.code,
    'reward_name', v_redemption.reward_name,
    'reward_type', v_redemption.reward_type,
    'points_spent', v_redemption.points_spent,
    'customer_id', v_customer_id,
    'customer_nickname', v_nickname,
    'status', v_redemption.status,
    'origin', v_redemption.origin,
    'created_at', v_redemption.created_at,
    'expires_at', v_token.expires_at,
    'consumed_at', v_token.consumed_at,
    'approved_at', v_redemption.approved_at,
    'delivered_at', v_redemption.delivered_at,
    'can_redeem', v_can_redeem,
    'reason', v_reason,
    'role', v_membership.role
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Confirmar entrega con el token (sin `business_id`).
--    Aprueba y entrega en una sola transacción; consume el token.
-- ---------------------------------------------------------------------
create or replace function public.redemption_redeem_by_token(
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_token public.loyalty_redemption_tokens;
  v_redemption public.loyalty_redemptions;
  v_membership public.business_memberships;
  v_nickname text;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{20,100}$' then
    raise exception 'invalid_token';
  end if;

  perform private.consume_rate_limit('redemption_scan_redeem:' || v_uid::text, 20, 60);

  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');

  select * into v_token
    from public.loyalty_redemption_tokens
   where token_hash = v_hash
   for update;

  if not found then
    raise exception 'invalid_token';
  end if;

  v_membership := public.business_current_membership(v_token.business_id);

  if v_membership.role not in ('admin', 'encargado') then
    raise exception 'forbidden';
  end if;
  if v_membership.role = 'encargado' and not v_membership.can_approve_redemptions then
    raise exception 'forbidden';
  end if;

  select * into v_redemption
    from public.loyalty_redemptions
   where id = v_token.redemption_id
     and business_id = v_token.business_id
   for update;

  if not found then
    raise exception 'redemption_not_found';
  end if;

  -- Reutilización del token o estados ya resueltos.
  if v_redemption.status = 'delivered' then
    raise exception 'redemption_already_delivered';
  end if;
  if v_redemption.status <> 'pending' then
    raise exception 'redemption_not_pending';
  end if;
  if v_token.consumed_at is not null then
    raise exception 'token_already_consumed';
  end if;
  if v_token.expires_at <= v_now then
    raise exception 'token_expired';
  end if;

  select p.nickname
    into v_nickname
    from public.loyalty_point_accounts a
    join public.profiles p on p.id = a.customer_id
   where a.id = v_redemption.account_id;

  update public.loyalty_redemptions
     set status = 'delivered',
         origin = 'qr_scan',
         approved_by = v_uid,
         approved_at = v_now,
         delivered_at = v_now
   where id = v_redemption.id;

  update public.loyalty_redemption_tokens
     set consumed_at = v_now,
         consumed_by = v_uid
   where id = v_token.id;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    v_redemption.business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.scanned',
    'loyalty_redemption',
    v_redemption.id::text,
    jsonb_build_object(
      'code', v_redemption.code,
      'reward_name', v_redemption.reward_name,
      'points_spent', v_redemption.points_spent,
      'customer_nickname', v_nickname,
      'channel', 'qr_scan'
    )
  );

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    v_redemption.business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'redemption.delivered',
    'loyalty_redemption',
    v_redemption.id::text,
    jsonb_build_object(
      'reward_name', v_redemption.reward_name,
      'points_spent', v_redemption.points_spent,
      'via', 'qr_scan'
    )
  );

  return jsonb_build_object(
    'business_id', v_redemption.business_id,
    'redemption_id', v_redemption.id,
    'code', v_redemption.code,
    'reward_name', v_redemption.reward_name,
    'points_spent', v_redemption.points_spent,
    'customer_nickname', v_nickname,
    'status', 'delivered',
    'origin', 'qr_scan',
    'delivered_at', v_now,
    'role', v_membership.role
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Listado del negocio con origen y nickname.
--    La firma cambia (columnas y parámetro nuevos), por eso se recrea.
-- ---------------------------------------------------------------------
drop function if exists public.loyalty_redemptions_list(
  uuid, public.redemption_request_status, integer, integer
);

create or replace function public.loyalty_redemptions_list(
  p_business_id uuid,
  p_status public.redemption_request_status default null,
  p_limit integer default 100,
  p_offset integer default 0,
  p_origin text default null
)
returns table (
  id uuid,
  reward_name text,
  reward_type public.loyalty_reward_type,
  points_spent integer,
  code text,
  status public.redemption_request_status,
  created_at timestamptz,
  approved_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  customer_id uuid,
  customer_email text,
  origin text,
  customer_nickname text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  if p_origin is not null and p_origin not in ('manual', 'qr_scan') then
    raise exception 'invalid_origin';
  end if;

  return query
    select r.id, r.reward_name, r.reward_type, r.points_spent, r.code, r.status,
           r.created_at, r.approved_at, r.delivered_at, r.cancelled_at,
           a.customer_id, p.email, r.origin, p.nickname
      from public.loyalty_redemptions r
      join public.loyalty_point_accounts a on a.id = r.account_id
      join public.profiles p on p.id = a.customer_id
     where r.business_id = p_business_id
       and (p_status is null or r.status = p_status)
       and (p_origin is null or r.origin = p_origin)
     order by r.created_at desc
     limit v_limit offset v_offset;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Permisos
-- ---------------------------------------------------------------------
revoke execute on function public.redemption_token_context(text) from public;
revoke execute on function public.redemption_redeem_by_token(text) from public;
revoke execute on function public.loyalty_redemptions_list(
  uuid, public.redemption_request_status, integer, integer, text
) from public;

grant execute on function public.redemption_token_context(text) to authenticated;
grant execute on function public.redemption_redeem_by_token(text) to authenticated;
grant execute on function public.loyalty_redemptions_list(
  uuid, public.redemption_request_status, integer, integer, text
) to authenticated;

comment on function public.redemption_token_context(text) is
  'Resuelve negocio, recompensa y cliente desde un token QR. No acepta business_id.';
comment on function public.redemption_redeem_by_token(text) is
  'Aprueba y entrega una recompensa escaneada consumiendo el token en una sola transacción.';
