-- Só para Postgres PURO (sem Supabase): o mínimo de `auth` que a migration
-- 20261015140000 e o test.sql usam. NUNCA aplicar em projeto Supabase — lá o
-- schema `auth` é do GoTrue.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id                 uuid primary key,
  phone              text,
  email              text,
  is_anonymous       boolean not null default false,
  email_confirmed_at timestamptz,
  phone_confirmed_at timestamptz,
  raw_user_meta_data jsonb
);

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'sub', '')::uuid
$$;
