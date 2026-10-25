-- =====================================================================
-- Funciones de consulta faltantes (listar negocios, obtener programa)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Listar negocios a los que pertenece el usuario autenticado
-- ---------------------------------------------------------------------
create or replace function public.businesses_list()
returns table (
  id uuid,
  name text,
  slug text,
  timezone text,
  operating_days smallint[],
  is_active boolean,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  return query
    select b.id, b.name, b.slug, b.timezone, b.operating_days, b.is_active,
           b.created_by, b.created_at, b.updated_at
      from public.businesses b
     where exists (
             select 1 from public.business_memberships m
              where m.business_id = b.id and m.user_id = v_uid
           )
     order by b.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------
-- Obtener el programa de puntos de un negocio
-- ---------------------------------------------------------------------
create or replace function public.loyalty_program_get(
  p_business_id uuid
)
returns public.loyalty_programs
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_program public.loyalty_programs;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  select * into v_program
    from public.loyalty_programs
   where business_id = p_business_id;

  if not found then
    raise exception 'program_not_found';
  end if;

  return v_program;
end;
$$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
grant execute on function public.businesses_list() to authenticated;
grant execute on function public.loyalty_program_get(uuid) to authenticated;
