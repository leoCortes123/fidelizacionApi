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
echo "== Pruebas de base de datos completadas =="
