-- =====================================================================
-- Endurecimiento de privilegios de funciones (Fase 6)
--
-- `CREATE OR REPLACE FUNCTION` conserva los privilegios, pero las funciones
-- creadas después de la revocación global de la Fase 0 heredaron el EXECUTE
-- implícito de PUBLIC. En particular `loyalty_transaction_post` quedaba
-- ejecutable por cualquier cliente autenticado (o anónimo) y, al ser
-- SECURITY DEFINER sin comprobación de rol, permitía acreditarse puntos.
--
-- Esta migración:
--   1. Revoca el EXECUTE implícito de PUBLIC en todas las funciones.
--   2. Elimina el overload obsoleto de loyalty_transaction_post.
--   3. Blinda explícitamente la firma vigente (solo uso interno).
-- Los GRANT explícitos a `authenticated` y `anon` de las RPC públicas se
-- mantienen; solo se retira el privilegio heredado de PUBLIC.
-- =====================================================================

revoke execute on all functions in schema public from public;

-- Overload antiguo (orden de argumentos previo a la Fase 0). No lo usa
-- ninguna función vigente.
drop function if exists public.loyalty_transaction_post(
  uuid,
  uuid,
  public.point_movement_type,
  integer,
  text,
  uuid,
  text,
  uuid,
  text
);

revoke execute on function public.loyalty_transaction_post(
  uuid,
  uuid,
  public.point_movement_type,
  integer,
  text,
  uuid,
  text,
  text,
  uuid
) from public;
revoke execute on function public.loyalty_transaction_post(
  uuid,
  uuid,
  public.point_movement_type,
  integer,
  text,
  uuid,
  text,
  text,
  uuid
) from anon;
revoke execute on function public.loyalty_transaction_post(
  uuid,
  uuid,
  public.point_movement_type,
  integer,
  text,
  uuid,
  text,
  text,
  uuid
) from authenticated;

-- Comprobaciones: el cliente no puede ejecutar el posteo interno y solo
-- queda una firma vigente.
do $$
begin
  if exists (
    select 1 from pg_proc
     where proname = 'loyalty_transaction_post'
       and pronamespace = 'public'::regnamespace
       and pg_get_function_identity_arguments(oid) like '%p_idempotency_key text, p_created_by uuid, p_reference_type%'
  ) then
    raise exception 'persiste el overload obsoleto de loyalty_transaction_post';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.loyalty_transaction_post(uuid,uuid,public.point_movement_type,integer,text,uuid,text,text,uuid)',
    'execute'
  ) then
    raise exception 'authenticated aún puede ejecutar loyalty_transaction_post';
  end if;
end;
$$;
