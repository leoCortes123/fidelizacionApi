-- Stub mínimo del entorno Supabase para probar las migraciones en PostgreSQL puro.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end
$$;

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key,
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

create schema if not exists tests;

create or replace function tests.as_user(p_uid uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', p_uid::text, 'role', 'authenticated')::text,
    true
  );
end;
$$;

create or replace function tests.assert(p_ok boolean, p_label text)
returns void
language plpgsql
as $$
begin
  if p_ok is distinct from true then
    raise exception 'ASSERT FAILED: %', p_label;
  end if;
  raise notice 'PASS: %', p_label;
end;
$$;

create or replace function tests.assert_eq_int(p_actual bigint, p_expected bigint, p_label text)
returns void
language plpgsql
as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERT FAILED: % (esperado %, obtenido %)', p_label, p_expected, p_actual;
  end if;
  raise notice 'PASS: %', p_label;
end;
$$;

create or replace function tests.assert_eq_text(p_actual text, p_expected text, p_label text)
returns void
language plpgsql
as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERT FAILED: % (esperado %, obtenido %)', p_label, p_expected, p_actual;
  end if;
  raise notice 'PASS: %', p_label;
end;
$$;

create or replace function tests.expect_error(p_sql text, p_expected text)
returns void
language plpgsql
as $$
begin
  execute p_sql;
  raise exception 'ASSERT FAILED: se esperaba el error "%" en: %', p_expected, p_sql;
exception
  when others then
    if position(p_expected in sqlerrm) = 0 then
      raise exception 'ASSERT FAILED: se esperaba "%", se obtuvo "%"', p_expected, sqlerrm;
    end if;
    raise notice 'PASS: error esperado "%"', p_expected;
end;
$$;

create or replace function tests.expect_sqlstate(p_sql text, p_state text)
returns void
language plpgsql
as $$
declare
  v_state text;
begin
  begin
    execute p_sql;
  exception
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> p_state then
        raise exception 'ASSERT FAILED: SQLSTATE esperado %, obtenido % (%)', p_state, v_state, sqlerrm;
      end if;
      raise notice 'PASS: SQLSTATE esperado %', p_state;
      return;
  end;
  raise exception 'ASSERT FAILED: se esperaba SQLSTATE % en: %', p_state, p_sql;
end;
$$;

grant usage on schema tests to anon, authenticated, service_role;
grant execute on all functions in schema tests to anon, authenticated, service_role;
