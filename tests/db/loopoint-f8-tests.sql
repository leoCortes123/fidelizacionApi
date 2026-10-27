-- =====================================================================
-- Loopoint F8 — Auditoría legible (B14)
--
--  1. El RPC devuelve el nombre del actor (join con profiles).
--  2. Filtro por categoría/operación y por varias categorías.
--  3. Filtro por actor (nombre o correo).
--  4. Filtro por rango de fechas.
--  5. Búsqueda libre en metadata/entidad/actor, con % y _ literales.
--  6. Paginación y total_count con filtros.
--  7. Permisos: admin y encargado leen; cliente y ajeno no.
--  8. Rango de fechas inválido.
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('90000000-0000-4000-8000-000000000001', 'f8-admin@example.test', '{"full_name":"Admin F8"}'),
  ('90000000-0000-4000-8000-000000000002', 'f8-encargado@example.test', '{"full_name":"Encargado F8"}'),
  ('90000000-0000-4000-8000-000000000003', 'f8-cliente@example.test', '{"full_name":"Cliente F8"}'),
  ('90000000-0000-4000-8000-000000000004', 'f8-ajeno@example.test', '{"full_name":"Ajeno F8"}');

set local role authenticated;
select tests.as_user('90000000-0000-4000-8000-000000000001');

select r->>'business_id' as biz
  from (select public.business_register('Café F8', 'cafe-f8') as r) s \gset

select public.business_membership_create(
  :'biz'::uuid, '90000000-0000-4000-8000-000000000002', 'encargado', true
);
select public.business_membership_create(
  :'biz'::uuid, '90000000-0000-4000-8000-000000000003', 'cliente', false
);

-- Filas deterministas para probar filtros y fechas. La fila
-- `business.created` la creó `business_register` hace un instante.
reset role;
insert into public.business_audit_logs (
  business_id, actor_id, actor_email, operation, entity_type, entity_id,
  metadata, created_at
) values
  (
    :'biz'::uuid,
    '90000000-0000-4000-8000-000000000001',
    'f8-admin@example.test',
    'purchase.registered',
    'loyalty_purchase_event',
    'evento-f8-1',
    '{"amount_cop":15500,"eligible_amount_cop":15500,"points_earned":15,"customer_id":"90000000-0000-4000-8000-000000000003"}'::jsonb,
    now() - interval '2 hours'
  ),
  (
    :'biz'::uuid,
    '90000000-0000-4000-8000-000000000001',
    'f8-admin@example.test',
    'redemption.delivered',
    'loyalty_redemption',
    'canje-f8-1',
    '{"reward_name":"Café gratis","points_spent":10}'::jsonb,
    now() - interval '1 hour'
  ),
  (
    :'biz'::uuid,
    '90000000-0000-4000-8000-000000000002',
    'f8-encargado@example.test',
    'campaign.created',
    'loyalty_campaign',
    'campana-f8-1',
    '{"name":"Cumpleaños F8","multiplier":2,"is_active":true}'::jsonb,
    now() - interval '30 minutes'
  ),
  (
    :'biz'::uuid,
    '90000000-0000-4000-8000-000000000002',
    'f8-encargado@example.test',
    'business.profile_updated',
    'business',
    :'biz',
    '{"before":{"name":"Café F8","city":null},"after":{"name":"Café F8 Centro","city":"Bogotá"}}'::jsonb,
    now() - interval '10 minutes'
  );

set local role authenticated;
select tests.as_user('90000000-0000-4000-8000-000000000001');

-- =====================================================================
-- 1. Total, nombre del actor y orden descendente
-- =====================================================================
select tests.assert_eq_int(
  (select max(total_count) from public.business_audit_log_page(:'biz'::uuid)),
  7,
  'la auditoría devuelve las siete operaciones del negocio'
);

select tests.assert_eq_text(
  (
    select actor_name
      from public.business_audit_log_page(:'biz'::uuid, 'purchase.registered')
     limit 1
  ),
  'Admin F8',
  'la auditoría resuelve el nombre del actor desde el perfil'
);

select tests.assert_eq_text(
  (
    select operation
      from public.business_audit_log_page(:'biz'::uuid)
     limit 1
  ),
  'membership.created',
  'las operaciones se ordenan de la más reciente a la más antigua'
);

-- =====================================================================
-- 2. Filtro por operación y por varias categorías
-- =====================================================================
select tests.assert_eq_int(
  (select count(*) from public.business_audit_log_page(:'biz'::uuid, 'purchase.')),
  1,
  'filtra por la categoría de compras'
);

select tests.assert_eq_int(
  (
    select count(*)
      from public.business_audit_log_page(:'biz'::uuid, 'campaign.,business.')
  ),
  3,
  'acepta varias categorías separadas por comas'
);

select tests.assert_eq_int(
  (
    select count(*)
      from public.business_audit_log_page(
        :'biz'::uuid, 'purchase.registered,redemption.delivered'
      )
  ),
  2,
  'acepta operaciones exactas separadas por comas'
);

-- =====================================================================
-- 3. Filtro por actor: nombre y correo
-- =====================================================================
select tests.assert_eq_int(
  (select count(*) from public.business_audit_log_page(:'biz'::uuid, null, 50, 0, 'Encargado F8')),
  2,
  'filtra por el nombre del actor'
);

select tests.assert_eq_int(
  (
    select count(*)
      from public.business_audit_log_page(:'biz'::uuid, null, 50, 0, 'f8-encargado@')
  ),
  2,
  'filtra por el correo del actor'
);

-- =====================================================================
-- 4. Rango de fechas (p_to es exclusivo)
-- =====================================================================
select tests.assert_eq_int(
  (
    select count(*)
      from public.business_audit_log_page(
        :'biz'::uuid, null, 50, 0, null,
        now() - interval '90 minutes', now() + interval '1 minute'
      )
  ),
  6,
  'filtra por rango de fechas reciente'
);

select tests.assert_eq_int(
  (
    select count(*)
      from public.business_audit_log_page(
        :'biz'::uuid, null, 50, 0, null, null, now() - interval '90 minutes'
      )
  ),
  1,
  'el límite superior excluye las operaciones posteriores'
);

-- =====================================================================
-- 5. Búsqueda libre y comodines literales
-- =====================================================================
select tests.assert_eq_int(
  (select count(*) from public.business_audit_log_page(:'biz'::uuid, null, 50, 0, null, null, null, 'Café gratis')),
  1,
  'la búsqueda libre encuentra texto dentro de la metadata'
);

select tests.assert_eq_int(
  (select count(*) from public.business_audit_log_page(:'biz'::uuid, null, 50, 0, null, null, null, 'Centro')),
  1,
  'la búsqueda libre encuentra cambios antes/después'
);

select tests.assert_eq_int(
  (select count(*) from public.business_audit_log_page(:'biz'::uuid, null, 50, 0, null, null, null, 'purchase%registered')),
  0,
  'el signo % se busca como texto literal, no como comodín'
);

select tests.assert_eq_int(
  (select count(*) from public.business_audit_log_page(:'biz'::uuid, null, 50, 0, null, null, null, 'purchase_registered')),
  0,
  'el guion bajo se busca como texto literal, no como comodín'
);

select tests.assert_eq_int(
  (select count(*) from public.business_audit_log_page(:'biz'::uuid, null, 50, 0, null, null, null, 'purchase.registered')),
  1,
  'la búsqueda exacta con punto sigue funcionando'
);

-- =====================================================================
-- 6. Paginación: total_count se mantiene y las páginas no se solapan
-- =====================================================================
select tests.assert_eq_int(
  (select count(*) from public.business_audit_log_page(:'biz'::uuid, null, 2, 0)),
  2,
  'la primera página respeta el límite'
);

select tests.assert_eq_int(
  (select max(total_count) from public.business_audit_log_page(:'biz'::uuid, null, 2, 2)),
  7,
  'total_count cuenta todas las filas del filtro, no solo la página'
);

select tests.assert(
  (
    select count(distinct id) = 4
      from (
        select id from public.business_audit_log_page(:'biz'::uuid, null, 2, 0)
        union all
        select id from public.business_audit_log_page(:'biz'::uuid, null, 2, 2)
      ) paged
  ),
  'las páginas devuelven filas distintas'
);

-- =====================================================================
-- 7. Permisos
-- =====================================================================
select tests.as_user('90000000-0000-4000-8000-000000000002');
select tests.assert_eq_int(
  (select max(total_count) from public.business_audit_log_page(:'biz'::uuid)),
  7,
  'el encargado puede leer la auditoría del negocio'
);

select tests.as_user('90000000-0000-4000-8000-000000000003');
select tests.expect_error(
  'select * from public.business_audit_log_page(''' || :'biz' || '''::uuid)',
  'forbidden'
);

select tests.as_user('90000000-0000-4000-8000-000000000004');
select tests.expect_error(
  'select * from public.business_audit_log_page(''' || :'biz' || '''::uuid)',
  'business_not_found_or_no_access'
);

-- =====================================================================
-- 8. Rango inválido
-- =====================================================================
select tests.as_user('90000000-0000-4000-8000-000000000001');
select tests.expect_error(
  'select * from public.business_audit_log_page(''' || :'biz'
    || '''::uuid, null, 50, 0, null, now(), now() - interval ''1 hour'')',
  'invalid_date_range'
);

rollback;
