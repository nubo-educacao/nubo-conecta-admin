-- Esqueleto mínimo para exercitar get_students_paginated fora de produção.
-- Só as tabelas/colunas que a função referencia.

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  phone text
);

CREATE TABLE public.user_profiles (
  id uuid PRIMARY KEY,
  full_name text,
  phone text,
  age int,
  race text,
  city text,
  state text,
  education text,
  is_nubo_student boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE public.user_income (
  user_id uuid,
  per_capita_income numeric
);

CREATE TABLE public.user_preferences (
  user_id uuid,
  family_income_per_capita numeric,
  quota_types text[]
);

CREATE TABLE public.partner_opportunities (
  id uuid PRIMARY KEY,
  name text
);

CREATE TABLE public.student_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  partner_id uuid,
  status text
);

CREATE TABLE public.user_opportunity_matches (
  profile_id uuid,
  unified_opportunity_id text,
  match_score numeric
);

CREATE TABLE public.institutions (
  id uuid PRIMARY KEY,
  name text
);

CREATE TABLE public.user_favorites (
  user_id uuid,
  course_id text,
  partner_opportunities_id text,
  institution_id uuid
);

CREATE VIEW public.v_unified_opportunities AS
  SELECT 'x'::text AS unified_id, 'x'::text AS title, 'x'::text AS provider_name;

-- Guard: alternável por GUC, para exercitar tanto o caminho permitido
-- quanto o negado.
CREATE FUNCTION public.is_backoffice_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce(current_setting('test.is_admin', true), 'on') = 'on';
$$;

-- ── Dados ────────────────────────────────────────────────────────────────────
-- Ordem de inserção deliberadamente embaralhada em relação a QUALQUER coluna,
-- para que "ordenado" não possa coincidir com "ordem física".
-- Os UUIDs são fixos e escolhidos para que a ordem por `id` seja diferente da
-- ordem por qualquer campo — é assim que o bug do ORDER BY p.id fica visível.
INSERT INTO public.user_profiles (id, full_name, phone, age, city, education, is_nubo_student, created_at) VALUES
  ('dddddddd-0000-0000-0000-000000000001', 'Carlos',  '11955550003', 30,   'Recife',    'medio',    false, '2026-01-03'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Ana',     '11955550001', 22,   'Sao Paulo', 'superior', true,  '2026-01-01'),
  ('cccccccc-0000-0000-0000-000000000003', 'Beatriz', NULL,          NULL, 'Belem',     'medio',    false, '2026-01-04'),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'Daniel',  '11955550002', 45,   'Curitiba',  'superior', true,  '2026-01-02');

INSERT INTO auth.users (id, phone) VALUES
  ('cccccccc-0000-0000-0000-000000000003', NULL);
