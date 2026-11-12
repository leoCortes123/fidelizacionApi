# Fidelización API (Supabase)

## Comandos
- Pruebas: `npm test` / `npm run test:db` (PostgreSQL 16 efímero en Docker).
- Supabase local: `npm run db:start`, `npm run db:reset`, `npm run db:status`.
- Remoto: `npm run db:push`, `npm run db:diff`.

## Estructura
- `supabase/migrations/` — 31 migraciones aditivas.
- `supabase/seed.sql`, `seed_test_data.sql`.
- `tests/db/` — suites SQL (run-tests, loyalty-*, loopoint-*, purchase-qr-tests).
- `scripts/test-db.sh` — orquesta PostgreSQL efímero.

## Convenciones
- Migraciones aditivas; no editar las ya aplicadas.
- Toda escritura sensible en RPC `SECURITY DEFINER` con RLS.
- Importes en COP como `integer`; fechas `timestamptz`.
- Hardening de grants: `anon` solo `business_public_get`, `purchase_qr_preview` y `business_member_invite_preview`.

## Contexto
- Esquema: `../documentacion/ai/schema-summary.md`.
- RPC: `../documentacion/ai/rpc-contract.md`.
- Gotchas: `../documentacion/ai/gotchas.md`.