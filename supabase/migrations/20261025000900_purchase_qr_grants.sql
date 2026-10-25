-- =====================================================================
-- Endurecimiento de permisos del flujo de venta con QR
--
-- Supabase concede EXECUTE a `anon` y `authenticated` por privilegios por
-- defecto al crear funciones nuevas en `public`. Aunque las funciones ya
-- validan `auth.uid()` y el rol del negocio, se retira el acceso anónimo
-- explícitamente para que solo la web autenticada pueda generar, listar o
-- anular ventas. La vista previa sigue siendo pública (la usa el QR antes
-- de iniciar sesión).
-- =====================================================================

revoke execute on function public.purchase_qr_create(uuid, integer) from anon;
revoke execute on function public.purchase_qr_create(uuid, integer) from public;

revoke execute on function public.purchase_qr_claim(text) from anon;
revoke execute on function public.purchase_qr_claim(text) from public;

revoke execute on function public.business_purchases_list(
  uuid, integer, integer, public.purchase_status
) from anon;
revoke execute on function public.business_purchases_list(
  uuid, integer, integer, public.purchase_status
) from public;

revoke execute on function public.purchase_qr_cancel(uuid, uuid, text) from anon;
revoke execute on function public.purchase_qr_cancel(uuid, uuid, text) from public;

-- La lógica interna solo la invocan funciones SECURITY DEFINER.
revoke execute on function private.accrue_purchase_points(
  uuid, uuid, uuid, integer, integer, text, uuid, text
) from anon;
revoke execute on function private.accrue_purchase_points(
  uuid, uuid, uuid, integer, integer, text, uuid, text
) from authenticated;
revoke execute on function private.accrue_purchase_points(
  uuid, uuid, uuid, integer, integer, text, uuid, text
) from public;
