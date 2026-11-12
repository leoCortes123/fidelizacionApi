-- =====================================================================
-- Pruebas SQL: invitaciones QR para miembros (`business_member_invites`)
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
\pset pager off

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('b1000000-0000-4000-8000-000000000001', 'inv-admin@example.test', '{"full_name":"Admin Invitador"}'),
  ('b1000000-0000-4000-8000-000000000002', 'inv-nuevo@example.test', '{"full_name":"Nuevo Encargado"}'),
  ('b1000000-0000-4000-8000-000000000003', 'inv-cliente@example.test', '{"full_name":"Cliente Existente"}'),
  ('b1000000-0000-4000-8000-000000000004', 'inv-intruso@example.test', '{"full_name":"Intruso Inv"}');

set local role authenticated;
select tests.as_user('b1000000-0000-4000-8000-000000000001');

select r->>'business_id' as biz
  from (select public.business_register('Café Invitación', 'cafe-invitacion') as r) s \gset

-- 1. Validaciones al crear invitación
select tests.expect_error(
  format($$select public.business_member_invite_create(%L::uuid, 'admin', false, 24)$$, :'biz'),
  'invalid_role'
);
select tests.expect_error(
  format($$select public.business_member_invite_create(%L::uuid, 'cliente', true, 24)$$, :'biz'),
  'invalid_approval_permission'
);

-- Crear invitación válida para encargado con aprobación
select r->>'token' as tok_encargado,
       r->>'invite_id' as inv_encargado
  from (select public.business_member_invite_create(:'biz'::uuid, 'encargado', true, 24) as r) s \gset

select tests.assert(length(:'tok_encargado') >= 20, 'se genera token válido');

-- 2. Un usuario ajeno y un cliente del negocio no pueden crear invitaciones
select tests.as_user('b1000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format($$select public.business_member_invite_create(%L::uuid, 'encargado', false, 24)$$, :'biz'),
  'business_not_found_or_no_access'
);

select tests.as_user('b1000000-0000-4000-8000-000000000003');
select public.business_join('cafe-invitacion');
select tests.expect_error(
  format($$select public.business_member_invite_create(%L::uuid, 'encargado', false, 24)$$, :'biz'),
  'forbidden'
);

-- 3. Preview funciona como anon sin exponer PII
reset role;
set local role anon;
select tests.assert_eq_text(
  public.business_member_invite_preview(:'tok_encargado')->>'status',
  'pending',
  'anon ve la invitación pendiente'
);
select tests.assert_eq_text(
  public.business_member_invite_preview(:'tok_encargado')->>'role',
  'encargado',
  'preview expone el rol destino'
);

-- 4. Usuario nuevo acepta la invitación -> queda encargado con aprobación
reset role;
set local role authenticated;
select tests.as_user('b1000000-0000-4000-8000-000000000002');

select r->>'role' as accepted_role,
       r->>'role_changed' as accepted_changed,
       r->>'already_accepted' as accepted_dup
  from (select public.business_member_invite_accept(:'tok_encargado') as r) s \gset

select tests.assert_eq_text(:'accepted_role', 'encargado', 'nuevo usuario queda encargado');
select tests.assert_eq_text(:'accepted_changed', 'false', 'primer ingreso no marca role_changed');
select tests.assert_eq_text(:'accepted_dup', 'false', 'primer accept no es duplicado');
select tests.assert(
  'registrar' = any(public.get_my_app_roles()),
  'get_my_app_roles incluye registrar tras aceptar invitación de encargado'
);

-- Re-aceptar por el mismo usuario es idempotente
select tests.assert_eq_text(
  public.business_member_invite_accept(:'tok_encargado')->>'already_accepted',
  'true',
  'mismo usuario re-aceptando es idempotente'
);

-- Otro usuario no puede reutilizar el QR ya aceptado
select tests.as_user('b1000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format($$select public.business_member_invite_accept(%L)$$, :'tok_encargado'),
  'invite_already_used'
);

-- 5. Usuario ya registrado como cliente se une y luego cambia de rol a encargado
select tests.as_user('b1000000-0000-4000-8000-000000000003');
select public.business_join('cafe-invitacion');

select tests.as_user('b1000000-0000-4000-8000-000000000001');
select r->>'token' as tok_upgrade
  from (select public.business_member_invite_create(:'biz'::uuid, 'encargado', false, 24) as r) s \gset

-- Un admin no puede degradarse aceptando su propio QR y tampoco consume el QR
select tests.expect_error(
  format($$select public.business_member_invite_accept(%L)$$, :'tok_upgrade'),
  'invite_already_admin'
);

select tests.as_user('b1000000-0000-4000-8000-000000000003');
select r->>'role' as up_role,
       r->>'previous_role' as up_prev,
       r->>'role_changed' as up_changed
  from (select public.business_member_invite_accept(:'tok_upgrade') as r) s \gset

select tests.assert_eq_text(:'up_role', 'encargado', 'cliente existente cambia a encargado');
select tests.assert_eq_text(:'up_prev', 'cliente', 'guarda rol previo cliente');
select tests.assert_eq_text(:'up_changed', 'true', 'marca role_changed=true');
select tests.assert(
  exists (
    select 1 from public.business_memberships
     where business_id = :'biz'::uuid
       and user_id = 'b1000000-0000-4000-8000-000000000003'
       and role = 'encargado'
       and can_approve_redemptions = false
  ),
  'la membresía del cliente se actualizó a encargado'
);

-- Auditoría registra invite_created, created y role_updated
select tests.assert(
  exists (
    select 1 from public.business_audit_logs
     where business_id = :'biz'::uuid and operation = 'membership.invite_created'
  ),
  'se audita membership.invite_created'
);
select tests.assert(
  exists (
    select 1 from public.business_audit_logs
     where business_id = :'biz'::uuid and operation = 'membership.created'
  ),
  'se audita membership.created'
);
select tests.assert(
  exists (
    select 1 from public.business_audit_logs
     where business_id = :'biz'::uuid and operation = 'membership.role_updated'
  ),
  'se audita membership.role_updated'
);

-- 5b. Encargado no puede ser degradado a cliente y conserva permiso de aprobación
select tests.as_user('b1000000-0000-4000-8000-000000000001');
select r->>'token' as tok_downgrade
  from (select public.business_member_invite_create(:'biz'::uuid, 'cliente', false, 24) as r) s \gset

select r->>'token' as tok_keep_perm
  from (select public.business_member_invite_create(:'biz'::uuid, 'encargado', false, 24) as r) s \gset

select tests.as_user('b1000000-0000-4000-8000-000000000002');
select tests.expect_error(
  format($$select public.business_member_invite_accept(%L)$$, :'tok_downgrade'),
  'invite_role_downgrade'
);
select tests.expect_error(
  format($$select public.business_member_invite_create(%L::uuid, 'cliente', false, 24)$$, :'biz'),
  'forbidden'
);
select r->>'can_approve_redemptions' as kept_approve
  from (select public.business_member_invite_accept(:'tok_keep_perm') as r) s \gset
select tests.assert_eq_text(:'kept_approve', 'true', 'encargado conserva can_approve_redemptions=true');

-- 5c. Revocación de invitación
select tests.as_user('b1000000-0000-4000-8000-000000000001');
select tests.expect_error(
  format($$select public.business_member_invite_create(%L::uuid, 'cliente', false, 0)$$, :'biz'),
  'invalid_invite_expiry'
);
select r->>'token' as tok_rev,
       r->>'invite_id' as inv_rev
  from (select public.business_member_invite_create(:'biz'::uuid, 'cliente', false, 24) as r) s \gset
select public.business_member_invite_revoke(:'biz'::uuid, :'inv_rev'::uuid);

set local role anon;
select tests.assert_eq_text(
  public.business_member_invite_preview(:'tok_rev')->>'status',
  'revoked',
  'preview reporta status=revoked'
);
reset role;
set local role authenticated;
select tests.as_user('b1000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format($$select public.business_member_invite_accept(%L)$$, :'tok_rev'),
  'invite_revoked'
);

-- 6. Invitación expirada falla en accept y muestra status=expired en preview
select tests.as_user('b1000000-0000-4000-8000-000000000001');
select r->>'token' as tok_exp,
       r->>'invite_id' as inv_exp
  from (select public.business_member_invite_create(:'biz'::uuid, 'cliente', false, 1) as r) s \gset

reset role;
update public.business_member_invites
   set expires_at = now() - interval '1 minute'
 where id = :'inv_exp'::uuid;

set local role anon;
select tests.assert_eq_text(
  public.business_member_invite_preview(:'tok_exp')->>'status',
  'expired',
  'preview reporta status=expired'
);

reset role;
set local role authenticated;
select tests.as_user('b1000000-0000-4000-8000-000000000004');
select tests.expect_error(
  format($$select public.business_member_invite_accept(%L)$$, :'tok_exp'),
  'invite_expired'
);

-- 7. Grants y RLS de seguridad
select tests.assert_eq_int(
  (select count(*)::integer from public.business_member_invites),
  0,
  'no-admin ve 0 filas en business_member_invites'
);

reset role;
select tests.assert(
  not has_column_privilege('authenticated', 'public.business_member_invites', 'token_hash', 'select'),
  'authenticated no puede leer token_hash directamente'
);
select tests.assert(
  not has_table_privilege('authenticated', 'public.business_member_invites', 'insert, update, delete'),
  'authenticated no puede escribir directamente en business_member_invites'
);
select tests.assert(
  not has_function_privilege('anon', 'public.business_member_invite_create(uuid, public.business_role, boolean, integer)', 'execute'),
  'anon no puede ejecutar business_member_invite_create'
);
select tests.assert(
  not has_function_privilege('anon', 'public.business_member_invite_accept(text)', 'execute'),
  'anon no puede ejecutar business_member_invite_accept'
);
select tests.assert(
  not has_function_privilege('anon', 'public.business_member_invite_revoke(uuid, uuid)', 'execute'),
  'anon no puede ejecutar business_member_invite_revoke'
);
select tests.assert(
  has_function_privilege('anon', 'public.business_member_invite_preview(text)', 'execute'),
  'anon puede ejecutar business_member_invite_preview'
);

rollback;
