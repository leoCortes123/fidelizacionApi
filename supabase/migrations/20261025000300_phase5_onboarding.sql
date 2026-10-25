-- =====================================================================
-- Fase 5 — Wizard de configuración inicial
--
-- El wizard necesita actualizar los datos del negocio (nombre, zona horaria
-- y días de operación) que hasta ahora solo se fijaban al registrarlo.
-- =====================================================================
create or replace function public.business_update(
  p_business_id uuid,
  p_name text default null,
  p_timezone text default null,
  p_operating_days smallint[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_business public.businesses;
  v_name text := btrim(coalesce(p_name, ''));
  v_timezone text := btrim(coalesce(p_timezone, ''));
  v_days smallint[];
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.require_business_role(p_business_id, array['admin']);

  select * into v_business
    from public.businesses
   where id = p_business_id
   for update;

  if not found then
    raise exception 'business_not_found';
  end if;

  if p_name is not null and (length(v_name) < 2 or length(v_name) > 120) then
    raise exception 'invalid_business_name';
  end if;

  if p_timezone is not null then
    if v_timezone = '' or not exists (
      select 1 from pg_timezone_names where name = v_timezone
    ) then
      raise exception 'invalid_timezone';
    end if;
  end if;

  if p_operating_days is not null then
    if exists (
      select 1 from unnest(p_operating_days) as d
       where d < 1 or d > 7
    ) then
      raise exception 'invalid_operating_days';
    end if;

    select array_agg(distinct d order by d) into v_days
      from unnest(p_operating_days) as d;

    if v_days is null or cardinality(v_days) = 0 then
      raise exception 'invalid_operating_days';
    end if;
  end if;

  update public.businesses
     set name = coalesce(nullif(v_name, ''), name),
         timezone = coalesce(nullif(v_timezone, ''), timezone),
         operating_days = coalesce(v_days, operating_days),
         updated_at = now()
   where id = p_business_id
  returning * into v_business;

  insert into public.business_audit_logs (
    business_id, actor_id, actor_email, operation, entity_type, entity_id, metadata
  ) values (
    p_business_id,
    v_uid,
    (select email from public.profiles where id = v_uid),
    'business.updated',
    'business',
    p_business_id::text,
    jsonb_build_object(
      'name', v_business.name,
      'timezone', v_business.timezone,
      'operating_days', to_jsonb(v_business.operating_days)
    )
  );

  return jsonb_build_object(
    'business_id', v_business.id,
    'name', v_business.name,
    'slug', v_business.slug,
    'timezone', v_business.timezone,
    'operating_days', to_jsonb(v_business.operating_days),
    'updated_at', v_business.updated_at
  );
end;
$$;

grant execute on function public.business_update(uuid, text, text, smallint[]) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_proc
     where proname = 'business_update'
       and pronamespace = 'public'::regnamespace
  ) then
    raise exception 'falta business_update';
  end if;
end;
$$;
