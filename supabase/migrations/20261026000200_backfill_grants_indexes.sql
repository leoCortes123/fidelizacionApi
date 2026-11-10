-- =====================================================================
-- Loopoint F9 — M7: Cierre y backfill
--
--   1. Backfill de nicknames para perfiles existentes que no lo tienen
--      (sin pisar los ya definidos).
--   2. Backfill de criterios de frecuencia para programas existentes
--      (las columnas ya tienen DEFAULT, pero aseguramos valores en NULL).
--   3. Barrido global de GRANT/REVOKE: todas las funciones SECURITY DEFINER
--      públicas ya tienen grant a `authenticated` y revoke de `public, anon`
--      salvo `business_public_get` y `purchase_qr_preview` que también
--      conceden a `anon`. No se crean funciones nuevas aquí; solo reaseguramos.
--   4. Comentarios en tablas/columnas que carecen de ellos.
--   5. Índices de apoyo adicionales detectados en revisiones de rendimiento.
--   6. Verificación final: ninguna función SECURITY DEFINER queda
--      ejecutable por PUBLIC.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Backfill de nicknames (perfiles creados antes de M1)
-- ---------------------------------------------------------------------
update public.profiles
   set nickname = private.nickname_generate(full_name)
 where nickname is null
   and full_name is not null
   and length(btrim(full_name)) > 0;

-- Perfiles sin nombre ni nickname → 'cliente'
update public.profiles
   set nickname = 'cliente'
 where nickname is null;

-- ---------------------------------------------------------------------
-- 2. Backfill de criterios de frecuencia (programas pre-M1)
--    Las columnas tienen DEFAULT, pero por si quedaron NULL.
-- ---------------------------------------------------------------------
update public.loyalty_programs
   set frequent_min_purchases = coalesce(frequent_min_purchases, 3),
       frequent_period_days   = coalesce(frequent_period_days, 90),
       frequent_min_spend_cop = coalesce(frequent_min_spend_cop, 0),
       frequent_active_days   = coalesce(frequent_active_days, 30),
       recovery_inactive_days = coalesce(recovery_inactive_days, 60)
 where frequent_min_purchases is null
    or frequent_period_days   is null
    or frequent_min_spend_cop is null
    or frequent_active_days   is null
    or recovery_inactive_days is null;

-- ---------------------------------------------------------------------
-- 3. Barrido de GRANT/REVOKE (idempotente)
--    Re-vocamos PUBLIC en todo y volvemos a conceder lo explícito.
--    Esto blinda cualquier función que se haya creado después de la
--    revocación global de la Fase 6 sin sus revocaciones propias.
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema public from anon;

-- Funciones públicas de lectura (p. ej. QR de invitación, vista previa de compra)
grant execute on function public.business_public_get(text) to anon, authenticated;
grant execute on function public.purchase_qr_preview(text) to anon, authenticated;

-- Todo lo demás: solo `authenticated` (excepto funciones internas denegadas)
do $$
declare
  v_sig text;
begin
  for v_sig in
    select p.oid::regprocedure::text
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
  loop
    -- servicio: puede ejecutar todo (bypass RLS, cron, backend)
    execute format('grant execute on function %s to service_role', v_sig);

    -- autenticados: todo excepto funciones internas que deben quedar cerradas
    if v_sig not like 'loyalty_transaction_post(%'
       and v_sig not like 'customer_redeem_reward(%'
       and v_sig not like 'points_expire_all_due(%'
       and v_sig not like 'loyalty_budget_snapshot_all(%'
    then
      execute format('grant execute on function %s to authenticated', v_sig);
    end if;
  end loop;
end;
$$;

-- Funciones privadas: reforzamos revocación a public/anon (idempotente)
revoke execute on function private.nickname_base(text) from public, anon;
revoke execute on function private.nickname_is_reserved(text) from public, anon;
revoke execute on function private.nickname_generate(text) from public, anon;
revoke execute on function private.customer_frequency(uuid, uuid) from public, anon;

-- ---------------------------------------------------------------------
-- 4. Comentarios en tablas/columnas
-- ---------------------------------------------------------------------
comment on table public.profiles is
  'Perfil público mínimo asociado a auth.users. Incluye nickname único y contador de cambios.';

comment on column public.profiles.nickname is
  'Alias público único (minúsculas, 3-24, letras/números/punto/guion). No se muestra en QR ni datos de canje.';

comment on column public.profiles.nickname_changes is
  'Cambios explícitos de nickname. El valor inicial y el autogenerado no cuentan. Máximo 2.';

comment on table public.businesses is
  'Negocio u organización que opera un programa de fidelización Loopoint.';

comment on column public.businesses.description is 'Descripción pública del negocio para la ficha /join/:slug.';
comment on column public.businesses.address is 'Dirección (calle, número) para la ficha pública.';
comment on column public.businesses.neighborhood is 'Barrio o localidad para la ficha pública.';
comment on column public.businesses.city is 'Ciudad para la ficha pública.';
comment on column public.businesses.phone_whatsapp is 'WhatsApp en formato E.164 (ej. +573001234567).';
comment on column public.businesses.phone is 'Teléfono fijo o móvil alternativo.';
comment on column public.businesses.instagram is 'Usuario de Instagram (sin @).';
comment on column public.businesses.website is 'URL del sitio web (https://...).';
comment on column public.businesses.logo_url is 'URL pública del logo en Storage (bucket business-assets).';

comment on table public.loyalty_programs is
  'Configuración del programa de loopoints por negocio.';

comment on column public.loyalty_programs.frequent_min_purchases is
  'Compras mínimas en la ventana para ser considerado frecuente (1-100).';
comment on column public.loyalty_programs.frequent_period_days is
  'Ventana en días para contar compras hacia frecuencia (7-3650).';
comment on column public.loyalty_programs.frequent_min_spend_cop is
  'Gasto mínimo por compra para que cuente hacia frecuencia (0-50M COP).';
comment on column public.loyalty_programs.frequent_active_days is
  'Días sin comprar tras los cuales un frecuente pasa a "activo" (1-365).';
comment on column public.loyalty_programs.recovery_inactive_days is
  'Días sin comprar tras los cuales un frecuente activo pasa a "en recuperación" (> frequent_active_days, 7-3650).';

comment on table public.products is
  'Catálogo de productos y combos del negocio.';

comment on column public.products.kind is
  'Tipo de producto: simple (unidad) o combo (conjunto de componentes).';

comment on table public.product_combo_items is
  'Componentes de un combo. Un solo nivel, sin auto-referencia ni ciclos.';

comment on table public.purchase_items is
  'Líneas de una compra (snapshot de nombre, precio y cantidad). Conserva el detalle aunque la carta cambie.';

comment on column public.purchase_items.name_snapshot is 'Nombre del producto/combo al momento de la compra.';
comment on column public.purchase_items.unit_price_cop is 'Precio unitario en COP al momento de la compra.';
comment on column public.purchase_items.is_combo is 'Indica si la línea corresponde a un combo.';
comment on column public.purchase_items.combo_detail is 'Desglose de componentes del combo (JSON).';

comment on table public.loyalty_redemptions is
  'Solicitudes de canje de recompensas. Incluye origen (manual/qr_scan) y token para QR escaneado.';

comment on column public.loyalty_redemptions.origin is
  'Origen de la solicitud: manual (cliente pide en app) o qr_scan (negocio escanea).';

comment on table public.loyalty_redemption_tokens is
  'Tokens de un solo uso para validar y entregar canjes por QR.';

comment on table public.loyalty_purchase_events is
  'Eventos de acumulación de loopoints por compra (idempotentes por idempotency_key).';

comment on table public.business_audit_logs is
  'Auditoría de operaciones sensibles por negocio. Incluye actor, entidad, metadata y timestamps.';

comment on table public.loyalty_campaigns is
  'Campañas promocionales temporales con multiplicador y/o bono fijo sobre la acumulación.';

comment on table public.loyalty_budget_snapshots is
  'Snapshots mensuales de presupuesto, ventas, costo redimido/pendiente y puntos emitidos/canjeados.';

-- ---------------------------------------------------------------------
-- 5. Índices de apoyo adicionales
-- ---------------------------------------------------------------------
-- Productos por negocio + kind (para listar combos vs simples en la carta)
create index if not exists products_business_kind_idx
  on public.products (business_id, kind, is_active);

-- Compras reclamadas por negocio + fecha (para dashboard/actividad)
-- Ya existe purchases_claimed_business_idx de M3.

-- Canjes por cuenta + estado + fecha (para /customer/canjes con filtro)
-- Ya existe loyalty_redemptions_account_idx de M4; el filtro por estado usa el índice compuesto de M6.

-- Puntos de cuenta por cliente + negocio (para resumen multi-negocio)
-- Ya existe loyalty_point_accounts_customer_business_idx de M4.

-- ---------------------------------------------------------------------
-- 6. Verificación final: ninguna función SECURITY DEFINER ejecutable por PUBLIC
-- ---------------------------------------------------------------------
do $$
declare
  v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and exists (
       select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
        where a.grantee = 0 and a.privilege_type = 'EXECUTE'
     );
  if v_bad is not null then
    raise exception 'Funciones SECURITY DEFINER ejecutables por PUBLIC: %', v_bad;
  end if;
end;
$$;

-- Comprobaciones de esquema
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'nickname'
  ) then
    raise exception 'profiles.nickname no existe';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'businesses'
       and column_name = 'logo_url'
  ) then
    raise exception 'businesses.logo_url no existe';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'loyalty_programs'
       and column_name = 'frequent_min_purchases'
  ) then
    raise exception 'loyalty_programs.frequent_min_purchases no existe';
  end if;

  if not exists (
    select 1 from pg_proc
     where proname = 'customer_businesses_summary'
       and pronamespace = 'public'::regnamespace
  ) then
    raise exception 'falta customer_businesses_summary';
  end if;

  if not exists (
    select 1 from pg_indexes
     where schemaname = 'public' and indexname = 'products_business_kind_idx'
  ) then
    raise exception 'falta products_business_kind_idx';
  end if;
end
$$;