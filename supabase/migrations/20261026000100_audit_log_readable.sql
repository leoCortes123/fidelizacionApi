-- =====================================================================
-- Fase 8 — Auditoría legible (B14)
--
--   1. `business_audit_log_page` devuelve el nombre del actor y acepta
--      filtros de operación, actor, rango de fechas y texto libre.
--   2. La operación puede enviarse como una lista separada por comas
--      (`purchase.,redemption.`) para filtrar por categorías completas.
--   3. El texto libre busca en operación, entidad, actor y metadata.
--   4. Índices de apoyo para operación y actor.
--
-- La firma conserva los cuatro primeros parámetros de la versión anterior,
-- así las llamadas posicionales existentes siguen funcionando.
-- =====================================================================

create index if not exists business_audit_logs_operation_idx
  on public.business_audit_logs (business_id, operation, created_at desc);

create index if not exists business_audit_logs_actor_idx
  on public.business_audit_logs (business_id, actor_id, created_at desc);

drop function if exists public.business_audit_log_page(
  uuid, text, integer, integer
);

create or replace function public.business_audit_log_page(
  p_business_id uuid,
  p_operation text default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_actor text default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_search text default null
)
returns table (
  id uuid,
  actor_email text,
  actor_name text,
  operation text,
  entity_type text,
  entity_id text,
  metadata jsonb,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_operations text[];
  v_actor text;
  v_search text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  if p_from is not null and p_to is not null and p_from >= p_to then
    raise exception 'invalid_date_range';
  end if;

  -- Cada patrón se escapa para que % y _ se busquen como texto literal.
  select coalesce(
           array_agg(
             replace(replace(replace(btrim(item), '\', '\\'), '%', '\%'), '_', '\_')
           ),
           '{}'
         )
    into v_operations
    from unnest(string_to_array(coalesce(p_operation, ''), ',')) as item
   where btrim(item) <> '';

  v_actor := replace(
    replace(replace(btrim(coalesce(p_actor, '')), '\', '\\'), '%', '\%'),
    '_', '\_'
  );
  v_search := replace(
    replace(replace(btrim(coalesce(p_search, '')), '\', '\\'), '%', '\%'),
    '_', '\_'
  );

  return query
    select a.id,
           a.actor_email,
           p.full_name as actor_name,
           a.operation,
           a.entity_type,
           a.entity_id,
           a.metadata,
           a.created_at,
           count(*) over () as total_count
      from public.business_audit_logs a
      left join public.profiles p on p.id = a.actor_id
     where a.business_id = p_business_id
       and (
         cardinality(v_operations) = 0
         or exists (
           select 1
             from unnest(v_operations) as op
            where a.operation ilike '%' || op || '%'
         )
       )
       and (
         v_actor = ''
         or coalesce(p.full_name, '') ilike '%' || v_actor || '%'
         or coalesce(a.actor_email, '') ilike '%' || v_actor || '%'
       )
       and (p_from is null or a.created_at >= p_from)
       and (p_to is null or a.created_at < p_to)
       and (
         v_search = ''
         or a.operation ilike '%' || v_search || '%'
         or a.entity_type ilike '%' || v_search || '%'
         or coalesce(a.entity_id, '') ilike '%' || v_search || '%'
         or coalesce(a.actor_email, '') ilike '%' || v_search || '%'
         or coalesce(p.full_name, '') ilike '%' || v_search || '%'
         or a.metadata::text ilike '%' || v_search || '%'
       )
     order by a.created_at desc, a.id desc
     limit v_limit offset v_offset;
end;
$$;

comment on function public.business_audit_log_page(
  uuid, text, integer, integer, text, timestamptz, timestamptz, text
) is 'Auditoría paginada y legible por negocio. Filtra por una o varias operaciones (separadas por comas), actor, fechas y texto libre; incluye el nombre del actor.';

revoke all on function public.business_audit_log_page(
  uuid, text, integer, integer, text, timestamptz, timestamptz, text
) from public;
grant execute on function public.business_audit_log_page(
  uuid, text, integer, integer, text, timestamptz, timestamptz, text
) to authenticated;

do $$
begin
  if not exists (
    select 1
      from pg_proc
     where proname = 'business_audit_log_page'
       and pronamespace = 'public'::regnamespace
       and pronargs = 8
  ) then
    raise exception 'falta business_audit_log_page con filtros de la Fase 8';
  end if;
end;
$$;
