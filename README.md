# Fidelización — API

Backend del sistema de fidelización. En este proyecto el API **es Supabase**:
PostgreSQL con RLS, funciones RPC, Auth y PostgREST. No hay un servidor HTTP
propio; la web y la futura app Android consumen Supabase directamente con la clave
pública, y toda la lógica sensible se ejecuta dentro de PostgreSQL.

> **Repositorio:** `https://github.com/leoCortes123/fidelizacionApi`
>
> Repositorios relacionados:
> [`fidelizacionWeb`](https://github.com/leoCortes123/fidelizacionWeb) ·
> [`fidelizacionApp`](https://github.com/leoCortes123/fidelizacionApp)
>
> La documentación completa vive en `documentacion/`, en el workspace local, al
> mismo nivel que los repositorios.

## Qué contiene

- **Esquema multiempresa:** negocios, membresías por negocio, productos, programas,
  recompensas, cuentas, libro de puntos, redenciones con QR, perfil económico,
  eventos de compra, auditoría, campañas y snapshots.
- **RPC:** registro de negocio, roles, programa, carta, recompensas, acumulación,
  reverso, solicitud/aprobación/entrega de canjes, campañas, vencimiento FIFO y
  snapshots.
- **RLS:** aislamiento por `business_id` y membresía, sin escrituras directas.
- **Semilla:** configuración y catálogo legacy.
- **Pruebas SQL:** 20 casos de aceptación, RLS, límites, idempotencia, saldo no
  negativo y concurrencia real con PostgreSQL efímero.

## Estructura

```text
supabase/
  config.toml           configuración local de Supabase
  migrations/           esquema, funciones, políticas y flujo administrativo
  seed.sql              configuración y catálogo inicial
tests/db/
  setup.sql             stub de auth/roles y utilidades de aserción
  run-tests.sql         pruebas legacy de integración y seguridad
  loyalty-phase0-tests.sql  cobertura detallada del módulo multiempresa
  loyalty-tests.sql     20 casos de aceptación de punta a punta
scripts/
  test-db.sh            PostgreSQL 16 efímero + migraciones + pruebas + concurrencia
```

## Requisitos

- Docker (para Supabase local y para las pruebas).
- Supabase CLI (se usa con `npx supabase`; no requiere instalación global).
- Node.js 22+ solo si quieres usar los scripts de `package.json`.

## Inicio rápido (local)

```bash
# 1. Levantar Supabase local
npm run db:start

# 2. Aplicar migraciones + seed
npm run db:reset

# 3. Ver la URL y la clave pública
npm run db:status
```

La URL local es `http://127.0.0.1:54321`. Copia la clave `anon` que muestra
`supabase status` al `.env` de la web.

Para detener el entorno:

```bash
npm run db:stop
```

## Proyecto alojado

```bash
npx supabase login
npx supabase link --project-ref <PROJECT_REF>
npx supabase db push
npx supabase db push --include-seed   # solo si necesitas la semilla
```

No ejecutes `supabase db reset` contra producción: borra datos.

### Administrador inicial

La lista de correos que reciben `admin` automáticamente **no se versiona**. Antes
del primer registro del administrador, ejecuta en el SQL Editor (o con `psql`):

```sql
insert into private.bootstrap_admins (email)
values ('correo-del-administrador@dominio.com')
on conflict (email) do nothing;
```

Si la cuenta ya existe, habilítala directamente:

```sql
insert into public.user_roles (user_id, role)
select id, 'admin'
from auth.users
where email = 'correo-del-administrador@dominio.com'
on conflict (user_id, role) do nothing;
```

La tabla `private.bootstrap_admins` no está expuesta por la API y no tiene permisos
para `anon` ni `authenticated`.

## Pruebas

```bash
npm test          # igual que npm run test:db
```

El script:

1. levanta PostgreSQL 16 en un contenedor efímero;
2. crea el stub de `auth` y los roles de Supabase;
3. aplica todas las migraciones y la semilla;
4. ejecuta las aserciones SQL, los 20 casos de aceptación y dos pruebas de
   concurrencia (reclamo de QR y aprobación de canje).

Resultado esperado: **275 aserciones** y **2 pruebas de concurrencia** en verde.

## Seguridad

- La clave `service_role` / `sb_secret_…` **nunca** se usa en la web ni en la app.
- No se versionan `.env`, tokens de Supabase CLI, contraseñas ni el correo del
  administrador.
- `supabase/.temp` (estado de vinculación) está en `.gitignore`.
- La autorización se valida con `auth.uid()`, `has_role()` e `is_staff()` dentro de
  PostgreSQL.
- Consulta `documentacion/SEGURIDAD.md` y `documentacion/BASE_DE_DATOS.md`.

## Relación con los otros repositorios

| Repositorio | Responsabilidad |
| --- | --- |
| `fidelizacionApi` (este) | Esquema, RPC, RLS, Auth, seed y pruebas de base de datos |
| `fidelizacionWeb` | Sitio React: portal del cliente y panel administrativo |
| `fidelizacionApp` | Espacio reservado para la app Android (Kotlin/Compose) |
| `documentacion/` | Documentación funcional y técnica, fuera de los repositorios |

## Despliegue

El API se despliega en Supabase. Pasos, variables y verificación en
`documentacion/DESPLIEGUE.md`. Las migraciones son aditivas y deben probarse primero
en un proyecto de staging.

## Pendientes conocidos

- La verificación de correo está desactivada en la etapa actual.
- El vencimiento y los snapshots usan `pg_cron` si está disponible; si no, se
  ejecutan manualmente o con un programador externo.
- Las funciones `SECURITY DEFINER` rechazan llamadas sin sesión, pero conservan
  `EXECUTE` para `anon` por los privilegios por defecto de Supabase.
- La anulación de canjes exige rol admin y queda auditada, sin segunda aprobación.
