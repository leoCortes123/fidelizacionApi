-- =====================================================================
-- Corrección: "column reference \"id\" is ambiguous"
--
-- `products_list` devuelve columnas con `returns table (id, name, ...)`.
-- En PL/pgSQL esos nombres se convierten en variables locales, así que la
-- consulta `select id, name, ... from public.products` era ambigua entre la
-- variable de salida y la columna de la tabla. PostgreSQL abortaba con:
--   column reference "id" is ambiguous
-- La pantalla Carta (`/admin/products`) mostraba "No pudimos cargar la
-- información" porque useProducts llama a esta RPC.
--
-- Solución: calificar todas las columnas con el alias de la tabla.
-- =====================================================================
create or replace function public.products_list(
  p_business_id uuid,
  p_only_active boolean default true
)
returns table (
  id uuid,
  name text,
  description text,
  price_cop integer,
  cost_cop integer,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin', 'encargado']);

  return query
    select p.id,
           p.name,
           p.description,
           p.price_cop,
           p.cost_cop,
           p.is_active,
           p.created_at,
           p.updated_at
      from public.products p
     where p.business_id = p_business_id
       and (not p_only_active or p.is_active)
     order by p.name;
end;
$$;

grant execute on function public.products_list(uuid, boolean) to authenticated;
