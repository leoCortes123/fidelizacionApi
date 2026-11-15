-- =====================================================================
-- Loopoint — Permitir a clientes miembros del negocio consultar la carta
-- activa (`products_list` con `p_only_active = true`) sin exponer `cost_cop`.
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
  updated_at timestamptz,
  kind text,
  combo_items jsonb,
  image_url text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_membership public.business_memberships;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  if p_only_active is true then
    v_membership := public.require_business_role(
      p_business_id,
      array['admin', 'encargado', 'cliente']
    );
  else
    v_membership := public.require_business_role(
      p_business_id,
      array['admin', 'encargado']
    );
  end if;

  return query
    select p.id,
           p.name,
           p.description,
           p.price_cop,
           case
             when v_membership.role in ('admin', 'encargado') then p.cost_cop
             else null::integer
           end as cost_cop,
           p.is_active,
           p.created_at,
           p.updated_at,
           p.kind,
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'product_id', ci.component_product_id,
                      'name', cp.name,
                      'quantity', ci.quantity,
                      'unit_price_cop', cp.price_cop
                    ) order by cp.name)
               from public.product_combo_items ci
               join public.products cp on cp.id = ci.component_product_id
              where ci.combo_id = p.id
           ), '[]'::jsonb) as combo_items,
           p.image_url
      from public.products p
     where p.business_id = p_business_id
       and (not p_only_active or p.is_active)
     order by p.name;
end;
$$;

grant execute on function public.products_list(uuid, boolean) to authenticated, service_role;
revoke execute on function public.products_list(uuid, boolean) from public, anon;

comment on function public.products_list(uuid, boolean) is
  'Lista productos del negocio. Staff ve activos/inactivos y costo; clientes miembros solo ven productos activos y sin cost_cop.';
