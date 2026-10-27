#!/usr/bin/env bash
# Levanta un PostgreSQL efímero, aplica migraciones + seed y ejecuta las
# pruebas de integración (RLS, RPC, transacciones y concurrencia).
set -euo pipefail

CONTAINER="tacos-puntos-db-test-$$"
IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
DB_USER="postgres"
DB_NAME="tacos"
TMP_DIR="$(mktemp -d)"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "== Iniciando PostgreSQL de pruebas ($IMAGE) =="
docker run --rm -d \
  --name "$CONTAINER" \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB="$DB_NAME" \
  -p 127.0.0.1::5432 \
  "$IMAGE" >/dev/null

for _ in $(seq 1 90); do
  if docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c 'select 1' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c 'select 1' >/dev/null 2>&1; then
  echo "PostgreSQL no arrancó a tiempo" >&2
  exit 1
fi

PSQL=(docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q)

echo "== Entorno Supabase simulado =="
"${PSQL[@]}" < tests/db/setup.sql

echo "== Aplicando migraciones =="
for migration in supabase/migrations/*.sql; do
  echo "   - $migration"
  "${PSQL[@]}" < "$migration"
done

echo "== Datos iniciales =="
"${PSQL[@]}" < supabase/seed.sql

echo "== Pruebas de integración =="
"${PSQL[@]}" < tests/db/run-tests.sql

echo "== Pruebas Fase 0 (multiempresa, roles, QR y acumulación) =="
"${PSQL[@]}" < tests/db/loyalty-phase0-tests.sql

echo "== Pruebas del flujo de venta con QR por negocio =="
"${PSQL[@]}" < tests/db/purchase-qr-tests.sql

echo "== Pruebas de aceptación Fase 7 (20 casos) =="
"${PSQL[@]}" < tests/db/loyalty-tests.sql

echo "== Pruebas Loopoint F2 (identidad, negocio, logo y frecuencia) =="
"${PSQL[@]}" < tests/db/loopoint-tests.sql

echo "== Pruebas Loopoint F4 (combos, ítems, detalle y métricas) =="
"${PSQL[@]}" < tests/db/loopoint-f4-tests.sql

echo "== Pruebas Loopoint F6 (canje escaneado por QR) =="
"${PSQL[@]}" < tests/db/loopoint-f6-tests.sql

echo "== Pruebas Loopoint F7 (portal del cliente multi-negocio) =="
"${PSQL[@]}" < tests/db/loopoint-f7-tests.sql

echo "== Pruebas Loopoint F8 (auditoría legible y filtros) =="
"${PSQL[@]}" < tests/db/loopoint-f8-tests.sql

echo "== Prueba de concurrencia: dos reclamos simultáneos =="
"${PSQL[@]}" <<'SQL'
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-000000000001', 'admin@example.test', '{"full_name":"Admin Prueba"}'),
  ('00000000-0000-4000-8000-000000000002', 'admin2@example.test', '{"full_name":"Admin Dos"}'),
  ('00000000-0000-4000-8000-000000000003', 'cliente1@example.test', '{"full_name":"Cliente Uno"}'),
  ('00000000-0000-4000-8000-000000000004', 'cliente2@example.test', '{"full_name":"Cliente Dos"}');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-4000-8000-000000000002', 'admin');
SQL

TOKEN="$("${PSQL[@]}" -tA <<'SQL' | tail -n1
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', false);
select public.create_purchase(15500)->>'token';
SQL
)"

if [[ -z "$TOKEN" ]]; then
  echo "No se pudo generar el token de concurrencia" >&2
  exit 1
fi

A_LOG="$TMP_DIR/concurrency-a.log"
B_LOG="$TMP_DIR/concurrency-b.log"

(
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -tA -c "
    set role authenticated;
    select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000003', false);
    select public.claim_purchase('$TOKEN');
    select pg_sleep(2);
  " >"$A_LOG" 2>&1
) &
A_PID=$!

sleep 0.7

set +e
docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -tA -c "
  set role authenticated;
  select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000004', false);
  select public.claim_purchase('$TOKEN');
" >"$B_LOG" 2>&1
B_STATUS=$?
set -e

wait "$A_PID"
A_STATUS=$?

if [[ $A_STATUS -ne 0 ]]; then
  echo "El primer reclamo debía ganar, pero falló:" >&2
  cat "$A_LOG" >&2
  exit 1
fi

if [[ $B_STATUS -eq 0 ]]; then
  echo "El segundo reclamo debía fallar, pero triunfó:" >&2
  cat "$B_LOG" >&2
  exit 1
fi

if ! grep -q "purchase_already_claimed" "$B_LOG"; then
  echo "El segundo reclamo falló con un error inesperado:" >&2
  cat "$B_LOG" >&2
  exit 1
fi

RESULT="$("${PSQL[@]}" -tA -c "
  select count(*) || '|' ||
         (select count(*) from public.points_ledger l join public.purchases p on p.id = l.purchase_id
           where p.token_hash = encode(extensions.digest('$TOKEN', 'sha256'), 'hex'))
    from public.purchases
   where token_hash = encode(extensions.digest('$TOKEN', 'sha256'), 'hex')
     and status = 'claimed';
")"

CLAIMED="${RESULT%%|*}"
LEDGER="${RESULT##*|}"

if [[ "$CLAIMED" != "1" || "$LEDGER" != "1" ]]; then
  echo "Concurrencia inconsistente: compras reclamadas=$CLAIMED, créditos=$LEDGER" >&2
  exit 1
fi

echo "PASS: solo un reclamo ganó y se acreditó una sola vez"

echo "== Prueba de concurrencia: dos clientes escanean el mismo QR =="
"${PSQL[@]}" <<'SQL'
insert into auth.users (id, email, raw_user_meta_data) values
  ('40000000-0000-4000-8000-000000000001', 'qr-conc-admin@example.test', '{"full_name":"Admin QR Concurrencia"}'),
  ('40000000-0000-4000-8000-000000000002', 'qr-conc-a@example.test', '{"full_name":"Cliente QR A"}'),
  ('40000000-0000-4000-8000-000000000003', 'qr-conc-b@example.test', '{"full_name":"Cliente QR B"}');
SQL

QR_TOKEN="$("${PSQL[@]}" -tA <<'SQL' | tail -n1
set role authenticated;
select set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', false);
select r->>'business_id' as biz
  from (select public.business_register('Venta QR Concurrencia', 'venta-qr-concurrencia') as r) s \gset
select public.loyalty_program_configure(
  :'biz'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);
select public.purchase_qr_create(:'biz'::uuid, 25000)->>'token';
SQL
)"

if [[ -z "$QR_TOKEN" ]]; then
  echo "No se pudo generar el QR de concurrencia" >&2
  exit 1
fi

QR_A_LOG="$TMP_DIR/qr-claim-a.log"
QR_B_LOG="$TMP_DIR/qr-claim-b.log"

(
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -tA -c "
    set role authenticated;
    select set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', false);
    select public.purchase_qr_claim('$QR_TOKEN');
    select pg_sleep(2);
  " >"$QR_A_LOG" 2>&1
) &
QR_A_PID=$!

sleep 0.7

set +e
docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -tA -c "
  set role authenticated;
  select set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000003', false);
  select public.purchase_qr_claim('$QR_TOKEN');
" >"$QR_B_LOG" 2>&1
QR_B_STATUS=$?
set -e

wait "$QR_A_PID"
QR_A_STATUS=$?

if [[ $QR_A_STATUS -ne 0 ]]; then
  echo "El primer cliente debía ganar el QR, pero falló:" >&2
  cat "$QR_A_LOG" >&2
  exit 1
fi

if [[ $QR_B_STATUS -eq 0 ]]; then
  echo "El segundo cliente debía fallar, pero triunfó:" >&2
  cat "$QR_B_LOG" >&2
  exit 1
fi

if ! grep -q "purchase_already_claimed" "$QR_B_LOG"; then
  echo "El segundo cliente falló con un error inesperado:" >&2
  cat "$QR_B_LOG" >&2
  exit 1
fi

QR_EVENTS="$("${PSQL[@]}" -tA -c "
  select count(*)
    from public.loyalty_purchase_events e
    join public.purchases p on p.id = e.purchase_id
   where p.token_hash = encode(extensions.digest('$QR_TOKEN', 'sha256'), 'hex');
")"

if [[ "$QR_EVENTS" != "1" ]]; then
  echo "Concurrencia QR inconsistente: eventos=$QR_EVENTS (esperado 1)" >&2
  exit 1
fi

echo "PASS: solo un cliente reclamó el QR y se acreditó una sola vez"

echo "== Prueba de concurrencia: dos aprobaciones simultáneas =="
"${PSQL[@]}" <<'SQL'
insert into auth.users (id, email, raw_user_meta_data) values
  ('30000000-0000-4000-8000-000000000001', 'concurrencia-dueno@example.test', '{"full_name":"Dueño Concurrencia"}'),
  ('30000000-0000-4000-8000-000000000002', 'concurrencia-encargado@example.test', '{"full_name":"Encargado Concurrencia"}'),
  ('30000000-0000-4000-8000-000000000003', 'concurrencia-cliente@example.test', '{"full_name":"Cliente Concurrencia"}');
SQL

CONCURRENCY_SETUP="$("${PSQL[@]}" -tA <<'SQL'
set role authenticated;
select set_config('request.jwt.claim.sub', '30000000-0000-4000-8000-000000000001', false);
select r->>'business_id' as biz
  from (
    select public.business_register('Concurrencia QR', 'concurrencia-redencion') as r
  ) s \gset
select public.business_membership_create(
  :'biz'::uuid, '30000000-0000-4000-8000-000000000002', 'encargado', true
);
select public.loyalty_program_configure(
  :'biz'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);
select r->>'id' as reward
  from (
    select public.loyalty_reward_upsert(
      :'biz'::uuid, 'fixed_discount', 'Canje concurrencia', 1,
      null, null, '', 2000, 1000
    ) as r
  ) s \gset
select set_config('request.jwt.claim.sub', '30000000-0000-4000-8000-000000000003', false);
select public.business_join('concurrencia-redencion');
select set_config('request.jwt.claim.sub', '30000000-0000-4000-8000-000000000001', false);
select public.loyalty_purchase_register(
  :'biz'::uuid, '30000000-0000-4000-8000-000000000003', 100000, 100000, 'concurrencia-compra-0001'
);
select set_config('request.jwt.claim.sub', '30000000-0000-4000-8000-000000000003', false);
select r->>'redemption_id' as redemption
  from (
    select public.reward_request_redemption(
      :'biz'::uuid, :'reward'::uuid, 'concurrencia-canje-0001'
    ) as r
  ) s \gset
\echo :biz :redemption
SQL
)"

read -r CONC_BIZ CONC_REDEMPTION <<<"$(echo "$CONCURRENCY_SETUP" | tail -n1)"
if [[ -z "$CONC_BIZ" || -z "$CONC_REDEMPTION" ]]; then
  echo "No se pudo preparar la concurrencia de aprobaciones" >&2
  echo "$CONCURRENCY_SETUP" >&2
  exit 1
fi

A_LOG="$TMP_DIR/approve-a.log"
B_LOG="$TMP_DIR/approve-b.log"

(
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -tA -c "
    set role authenticated;
    select set_config('request.jwt.claim.sub', '30000000-0000-4000-8000-000000000002', false);
    begin;
    select public.redemption_approve('$CONC_BIZ'::uuid, '$CONC_REDEMPTION'::uuid, true);
    select pg_sleep(2);
    commit;
  " >"$A_LOG" 2>&1
) &
A_PID=$!

sleep 0.7

set +e
docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -tA -c "
  set role authenticated;
  select set_config('request.jwt.claim.sub', '30000000-0000-4000-8000-000000000002', false);
  select public.redemption_approve('$CONC_BIZ'::uuid, '$CONC_REDEMPTION'::uuid, true);
" >"$B_LOG" 2>&1
B_STATUS=$?
set -e

wait "$A_PID"
A_STATUS=$?

if [[ $A_STATUS -ne 0 ]]; then
  echo "La primera aprobación debía ganar, pero falló:" >&2
  cat "$A_LOG" >&2
  exit 1
fi

if [[ $B_STATUS -eq 0 ]]; then
  echo "La segunda aprobación debía fallar, pero triunfó:" >&2
  cat "$B_LOG" >&2
  exit 1
fi

if ! grep -q "redemption_not_pending" "$B_LOG"; then
  echo "La segunda aprobación falló con un error inesperado:" >&2
  cat "$B_LOG" >&2
  exit 1
fi

APPROVAL_RESULT="$("${PSQL[@]}" -tA -c "
  select r.status::text || '|' ||
         (select count(*) from public.business_audit_logs
           where business_id = r.business_id
             and operation = 'redemption.approved'
             and entity_id = r.id::text) || '|' ||
         (select count(*) from public.loyalty_redemption_tokens
           where redemption_id = r.id and consumed_at is not null) || '|' ||
         (select balance from public.loyalty_point_accounts
           where business_id = r.business_id
             and customer_id = '30000000-0000-4000-8000-000000000003')
    from public.loyalty_redemptions r
   where r.id = '$CONC_REDEMPTION'::uuid;
")"

if [[ "$APPROVAL_RESULT" != "approved|1|1|99" ]]; then
  echo "Concurrencia de aprobación inconsistente: $APPROVAL_RESULT" >&2
  exit 1
fi

echo "PASS: solo una aprobación ganó, un token consumido y un solo débito"

echo "== Prueba de concurrencia: dos escaneos simultáneos del mismo QR =="
"${PSQL[@]}" <<'SQL'
insert into auth.users (id, email, raw_user_meta_data) values
  ('50000000-0000-4000-8000-000000000001', 'scan-conc-dueno@example.test', '{"full_name":"Dueño Scan"}'),
  ('50000000-0000-4000-8000-000000000002', 'scan-conc-enc1@example.test', '{"full_name":"Encargado Scan Uno"}'),
  ('50000000-0000-4000-8000-000000000003', 'scan-conc-enc2@example.test', '{"full_name":"Encargado Scan Dos"}'),
  ('50000000-0000-4000-8000-000000000004', 'scan-conc-cliente@example.test', '{"full_name":"Cliente Scan"}');
SQL

SCAN_SETUP="$("${PSQL[@]}" -tA <<'SQL'
set role authenticated;
select set_config('request.jwt.claim.sub', '50000000-0000-4000-8000-000000000001', false);
select r->>'business_id' as biz
  from (
    select public.business_register('Escaneo Concurrencia', 'escaneo-concurrencia') as r
  ) s \gset
select public.business_membership_create(
  :'biz'::uuid, '50000000-0000-4000-8000-000000000002', 'encargado', true
);
select public.business_membership_create(
  :'biz'::uuid, '50000000-0000-4000-8000-000000000003', 'encargado', true
);
select public.business_membership_create(
  :'biz'::uuid, '50000000-0000-4000-8000-000000000004', 'cliente', false
);
select public.loyalty_program_configure(
  :'biz'::uuid, 1000, 100, 365, 0.01, 0, 0, 0, 24, true
);
select public.loyalty_reward_upsert(
  :'biz'::uuid, 'fixed_discount', 'Canje escaneado concurrencia', 10,
  null, null, '', 2000, 1000
);
select public.loyalty_purchase_register(
  :'biz'::uuid, '50000000-0000-4000-8000-000000000004', 100000, 100000, 'scan-concurrencia-compra-0001'
);
select set_config('request.jwt.claim.sub', '50000000-0000-4000-8000-000000000004', false);
select r->>'token' as scan_token,
       r->>'redemption_id' as scan_redemption
  from (
    select public.reward_request_redemption(
      :'biz'::uuid,
      (select id from public.loyalty_rewards
        where business_id = :'biz'::uuid and name = 'Canje escaneado concurrencia'),
      'scan-concurrencia-canje-0001'
    ) as r
  ) s \gset
\echo :scan_token :scan_redemption
SQL
)"

read -r SCAN_TOKEN SCAN_REDEMPTION <<<"$(echo "$SCAN_SETUP" | tail -n1)"
if [[ -z "$SCAN_TOKEN" || -z "$SCAN_REDEMPTION" ]]; then
  echo "No se pudo preparar la concurrencia de escaneos" >&2
  echo "$SCAN_SETUP" >&2
  exit 1
fi

SCAN_A_LOG="$TMP_DIR/scan-a.log"
SCAN_B_LOG="$TMP_DIR/scan-b.log"

(
  docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -tA -c "
    set role authenticated;
    select set_config('request.jwt.claim.sub', '50000000-0000-4000-8000-000000000002', false);
    begin;
    select public.redemption_redeem_by_token('$SCAN_TOKEN');
    select pg_sleep(2);
    commit;
  " >"$SCAN_A_LOG" 2>&1
) &
SCAN_A_PID=$!

sleep 0.7

set +e
docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -tA -c "
  set role authenticated;
  select set_config('request.jwt.claim.sub', '50000000-0000-4000-8000-000000000003', false);
  select public.redemption_redeem_by_token('$SCAN_TOKEN');
" >"$SCAN_B_LOG" 2>&1
SCAN_B_STATUS=$?
set -e

wait "$SCAN_A_PID"
SCAN_A_STATUS=$?

if [[ $SCAN_A_STATUS -ne 0 ]]; then
  echo "El primer escaneo debía ganar, pero falló:" >&2
  cat "$SCAN_A_LOG" >&2
  exit 1
fi

if [[ $SCAN_B_STATUS -eq 0 ]]; then
  echo "El segundo escaneo debía fallar, pero triunfó:" >&2
  cat "$SCAN_B_LOG" >&2
  exit 1
fi

if ! grep -q "redemption_already_delivered" "$SCAN_B_LOG"; then
  echo "El segundo escaneo falló con un error inesperado:" >&2
  cat "$SCAN_B_LOG" >&2
  exit 1
fi

SCAN_RESULT="$("${PSQL[@]}" -tA -c "
  select r.status::text || '|' || r.origin || '|' ||
         (select count(*) from public.business_audit_logs
           where business_id = r.business_id
             and operation = 'redemption.scanned'
             and entity_id = r.id::text) || '|' ||
         (select count(*) from public.loyalty_redemption_tokens
           where redemption_id = r.id and consumed_at is not null) || '|' ||
         (select balance from public.loyalty_point_accounts
           where business_id = r.business_id
             and customer_id = '50000000-0000-4000-8000-000000000004')
    from public.loyalty_redemptions r
   where r.id = '$SCAN_REDEMPTION'::uuid;
")"

if [[ "$SCAN_RESULT" != "delivered|qr_scan|1|1|90" ]]; then
  echo "Concurrencia de escaneo inconsistente: $SCAN_RESULT" >&2
  exit 1
fi

echo "PASS: solo un escaneo entregó, un token consumido y una sola auditoría"

echo "== Pruebas de base de datos completadas =="
