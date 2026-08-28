-- 20260828100000_prouni_concurrency_normalization.sql
-- Normaliza a concorrência ProUni (AMPLA / COTA) de colunas fixas para linhas genéricas
-- com `concurrency_type`, alinhando o modelo com o SiSU.
--
-- FASES:
--   1. Adiciona colunas genéricas qt_ofertada/qt_ocupada em opportunities_prouni_vacancies
--   2. Cria índice único parcial para ProUni com concurrency_type
--   3. Backfill 2025.x: explode linhas NULL em AMPLA + COTA
--   4. Remove colunas legadas (bolsas_ampla_*, bolsas_cota_*, ds_tipo_bolsa)
--   5. Seed de concurrency_tag_rules para ProUni
--   6. Rebuild da matview v_unified_opportunities sem as colunas legadas
--   7. Rebuild do match engine (calculate_match) sem as colunas legadas

-- ====================================================================================
-- 1. Adicionar colunas genéricas
-- ====================================================================================
CREATE TABLE IF NOT EXISTS public.opportunities_prouni_vacancies (
  opportunity_id UUID PRIMARY KEY REFERENCES public.opportunities(id) ON DELETE CASCADE,
  bolsas_ampla_ofertada INTEGER DEFAULT 0,
  bolsas_cota_ofertada  INTEGER DEFAULT 0,
  bolsas_ampla_ocupada  INTEGER DEFAULT 0,
  bolsas_cota_ocupada   INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.opportunities_prouni_vacancies
  ADD COLUMN IF NOT EXISTS qt_ofertada INTEGER,
  ADD COLUMN IF NOT EXISTS qt_ocupada  INTEGER;

-- ====================================================================================
-- 2. Índice único parcial para ProUni com concurrency_type (espelha o SiSU)
-- ====================================================================================
CREATE UNIQUE INDEX IF NOT EXISTS uq_opportunities_prouni_concurrency
  ON public.opportunities (course_id, opportunity_type, year, semester, shift, scholarship_type, concurrency_type)
  WHERE opportunity_type = 'prouni' AND concurrency_type IS NOT NULL;

-- ====================================================================================
-- 3a. Criar oportunidades AMPLA a partir das ProUni existentes (concurrency_type IS NULL)
-- ====================================================================================
INSERT INTO public.opportunities (
  course_id, semester, shift, scholarship_type, year, opportunity_type,
  concurrency_type, concurrency_tags, cutoff_score, raw_data, scholarship_tags,
  created_at, updated_at
)
SELECT
  o.course_id, o.semester, o.shift, o.scholarship_type, o.year, o.opportunity_type,
  'AMPLA'                         AS concurrency_type,
  '[["AMPLA_CONCORRENCIA"]]'::jsonb AS concurrency_tags,
  o.cutoff_score,
  o.raw_data,
  o.scholarship_tags,
  o.created_at,
  now()
FROM public.opportunities o
WHERE o.opportunity_type = 'prouni' AND o.concurrency_type IS NULL
ON CONFLICT (course_id, opportunity_type, year, semester, shift, scholarship_type, concurrency_type) WHERE opportunity_type = 'prouni' AND concurrency_type IS NOT NULL DO NOTHING;

-- 3b. Vacâncias para as opps AMPLA recém-criadas
INSERT INTO public.opportunities_prouni_vacancies (
  opportunity_id, qt_ofertada, qt_ocupada
)
SELECT
  new_o.id,
  COALESCE(pv.bolsas_ampla_ofertada, 0) AS qt_ofertada,
  COALESCE(pv.bolsas_ampla_ocupada,  0) AS qt_ocupada
FROM public.opportunities old_o
JOIN public.opportunities_prouni_vacancies pv ON pv.opportunity_id = old_o.id
JOIN public.opportunities new_o
  ON  new_o.course_id       = old_o.course_id
  AND new_o.semester        = old_o.semester
  AND new_o.shift           = old_o.shift
  AND new_o.scholarship_type IS NOT DISTINCT FROM old_o.scholarship_type
  AND new_o.year            = old_o.year
  AND new_o.opportunity_type = 'prouni'
  AND new_o.concurrency_type = 'AMPLA'
WHERE old_o.opportunity_type = 'prouni'
  AND old_o.concurrency_type IS NULL
ON CONFLICT (opportunity_id) DO UPDATE SET
  qt_ofertada = EXCLUDED.qt_ofertada,
  qt_ocupada  = EXCLUDED.qt_ocupada,
  updated_at  = now();

-- 3c. Criar oportunidades COTA onde havia vagas de cota (bolsas_cota_ofertada > 0)
INSERT INTO public.opportunities (
  course_id, semester, shift, scholarship_type, year, opportunity_type,
  concurrency_type, concurrency_tags, cutoff_score, raw_data, scholarship_tags,
  created_at, updated_at
)
SELECT
  o.course_id, o.semester, o.shift, o.scholarship_type, o.year, o.opportunity_type,
  'COTA'                      AS concurrency_type,
  '[["PPI","INDIGENAS"]]'::jsonb AS concurrency_tags,
  o.cutoff_score,
  o.raw_data,
  o.scholarship_tags,
  o.created_at,
  now()
FROM public.opportunities o
JOIN public.opportunities_prouni_vacancies pv ON pv.opportunity_id = o.id
WHERE o.opportunity_type = 'prouni'
  AND o.concurrency_type IS NULL
  AND COALESCE(pv.bolsas_cota_ofertada, 0) > 0
ON CONFLICT (course_id, opportunity_type, year, semester, shift, scholarship_type, concurrency_type) WHERE opportunity_type = 'prouni' AND concurrency_type IS NOT NULL DO NOTHING;

-- 3d. Vacâncias para as opps COTA recém-criadas
INSERT INTO public.opportunities_prouni_vacancies (
  opportunity_id, qt_ofertada, qt_ocupada
)
SELECT
  new_o.id,
  COALESCE(pv.bolsas_cota_ofertada, 0) AS qt_ofertada,
  COALESCE(pv.bolsas_cota_ocupada,  0) AS qt_ocupada
FROM public.opportunities old_o
JOIN public.opportunities_prouni_vacancies pv ON pv.opportunity_id = old_o.id
JOIN public.opportunities new_o
  ON  new_o.course_id       = old_o.course_id
  AND new_o.semester        = old_o.semester
  AND new_o.shift           = old_o.shift
  AND new_o.scholarship_type IS NOT DISTINCT FROM old_o.scholarship_type
  AND new_o.year            = old_o.year
  AND new_o.opportunity_type = 'prouni'
  AND new_o.concurrency_type = 'COTA'
WHERE old_o.opportunity_type = 'prouni'
  AND old_o.concurrency_type IS NULL
  AND COALESCE(pv.bolsas_cota_ofertada, 0) > 0
ON CONFLICT (opportunity_id) DO UPDATE SET
  qt_ofertada = EXCLUDED.qt_ofertada,
  qt_ocupada  = EXCLUDED.qt_ocupada,
  updated_at  = now();

-- 3e. Deletar vacâncias das opps legadas (concurrency_type IS NULL)
DELETE FROM public.opportunities_prouni_vacancies pv
USING public.opportunities o
WHERE pv.opportunity_id = o.id
  AND o.opportunity_type = 'prouni'
  AND o.concurrency_type IS NULL;

-- 3f. Deletar opps ProUni legadas (concurrency_type IS NULL)
--     user_opportunity_matches e student_applications referenciadas pelo etl_rollback_log
--     são apagadas via ON DELETE CASCADE ou explicitamente aqui
DELETE FROM public.user_opportunity_matches uom
WHERE uom.unified_opportunity_id IN (
  SELECT ('mec_'||c.id::text)
  FROM public.opportunities o
  JOIN public.courses c ON c.id = o.course_id
  WHERE o.opportunity_type = 'prouni' AND o.concurrency_type IS NULL
);

DELETE FROM public.opportunities
WHERE opportunity_type = 'prouni' AND concurrency_type IS NULL;

-- ====================================================================================
-- 4. Remover colunas legadas de opportunities_prouni_vacancies
-- ====================================================================================
-- Dropar views e funções dependentes de v_unified_opportunities antes de remover as colunas legadas
DROP FUNCTION IF EXISTS public.search_opportunities(text);
DROP FUNCTION IF EXISTS public.get_unified_opportunities_by_distance(double precision, double precision);
DROP VIEW IF EXISTS public.v_unified_institutions CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.v_unified_opportunities CASCADE;

ALTER TABLE public.opportunities_prouni_vacancies
  DROP COLUMN IF EXISTS bolsas_ampla_ofertada,
  DROP COLUMN IF EXISTS bolsas_cota_ofertada,
  DROP COLUMN IF EXISTS bolsas_ampla_ocupada,
  DROP COLUMN IF EXISTS bolsas_cota_ocupada,
  DROP COLUMN IF EXISTS ds_tipo_bolsa;

-- ====================================================================================
-- 5. Seed concurrency_tag_rules para tipos ProUni
-- ====================================================================================
INSERT INTO public.concurrency_tag_rules (type_name, tags)
VALUES
  ('AMPLA',    '[["AMPLA_CONCORRENCIA"]]'::jsonb),
  ('COTA',     '[["PPI","INDIGENAS"]]'::jsonb),
  ('COTA_PPI', '[["PPI","INDIGENAS"]]'::jsonb),
  ('COTA_PCD', '[["PCD"]]'::jsonb)
ON CONFLICT (type_name) DO NOTHING;

-- ====================================================================================
-- 6. Rebuild matview v_unified_opportunities (remove bolsas_ampla/cota → usa qt_ofertada/qt_ocupada)
-- ====================================================================================

CREATE MATERIALIZED VIEW public.v_unified_opportunities AS

SELECT sisu_branch.* FROM (
  SELECT DISTINCT ON (c.id)
    ('mec_'::text || (c.id)::text) AS unified_id,
    c.course_name                  AS title,
    i.name                         AS provider_name,
    'sisu'::text                   AS type,
    'sisu'::text                   AS opportunity_type,
    'public_universities'::text    AS category,
    false                          AS is_partner,
    ((cp.city || ', '::text) || cp.state) AS location,
    (jsonb_build_array(o.shift) - 'null'::text) AS badges,
    o.created_at,
    NULL::text     AS external_redirect_url,
    false          AS external_redirect_enabled,
    p.status::text AS status,
    id_dates.start_date AS starts_at,
    id_dates.end_date   AS ends_at,
    NULL::numeric  AS match_score,
    NULL::text     AS institution_cover_url,
    sv_curr.nu_vagas_autorizadas,
    i.id           AS institution_id,
    ie.igc         AS institution_igc,
    ie.academic_organization  AS institution_organization,
    ie.administrative_category AS institution_category,
    ie.site        AS institution_site,
    NULL::jsonb    AS eligibility_criteria,
    NULL::jsonb    AS benefits,
    NULL::text     AS brand_color,
    jsonb_build_object(
      'redacao',    sv_curr.peso_redacao,
      'matematica', sv_curr.peso_matematica,
      'linguagens', sv_curr.peso_linguagens,
      'humanas',    sv_curr.peso_ciencias_humanas,
      'natureza',   sv_curr.peso_ciencias_natureza
    ) AS weights,
    sis.acronym    AS institution_acronym,
    cp.latitude,
    cp.longitude,
    s_curr.min_cutoff AS min_cutoff_score_current,
    s_prev.min_cutoff AS min_cutoff_score_prev,
    s_curr.max_cutoff AS max_cutoff_score_current,
    s_prev.max_cutoff AS max_cutoff_score_prev,
    sv_curr.qt_vagas_ofertadas AS qt_vagas_ofertadas_current,
    sv_prev.qt_vagas_ofertadas AS qt_vagas_ofertadas_prev,
    sv_curr.qt_inscricao       AS qt_inscricao_current,
    sv_prev_inscricao.qt_inscricao AS qt_inscricao_prev,
    sv_curr.nu_media_minima_enem AS nu_media_minima_enem_current,
    sv_prev.nu_media_minima_enem AS nu_media_minima_enem_prev,
    vc_curr.has_vagas_ociosas  AS vagas_ociosas_current,
    vc_prev.has_vagas_ociosas  AS vagas_ociosas_prev,
    public.f_unaccent(
      COALESCE(c.course_name, '') || ' ' ||
      COALESCE(i.name, '') || ' ' ||
      COALESCE(cp.city, '') || ' ' ||
      COALESCE(cp.state, '') || ' ' ||
      COALESCE(sis.acronym, '')
    ) AS search_text
  FROM public.opportunities o
    JOIN public.programs p ON p.type = 'sisu' AND p.status <> 'inactive'
    JOIN public.courses c      ON c.id = o.course_id
    JOIN public.campus cp      ON cp.id = c.campus_id
    JOIN public.institutions i ON i.id = cp.institution_id
    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'sisu' AND opp.course_id = o.course_id AND opp.year = p.cycle_year
    ) s_curr ON true
    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'sisu' AND opp.course_id = o.course_id AND opp.year = p.cycle_year - 1
    ) s_prev ON true
    LEFT JOIN LATERAL (
      SELECT d.start_date, d.end_date
      FROM public.important_dates d
      WHERE d.type = 'sisu' AND d.controls_opportunity_dates = true
      ORDER BY d.start_date DESC LIMIT 1
    ) id_dates ON true
    LEFT JOIN LATERAL (
      SELECT sv.*
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.year = p.cycle_year AND op.opportunity_type = 'sisu'
      LIMIT 1
    ) sv_curr ON true
    LEFT JOIN LATERAL (
      SELECT sv.qt_vagas_ofertadas, sv.nu_media_minima_enem
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.year = p.cycle_year - 1 AND op.opportunity_type = 'sisu'
      LIMIT 1
    ) sv_prev ON true
    LEFT JOIN LATERAL (
      SELECT sv.qt_inscricao
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.year = p.cycle_year - 1 AND op.opportunity_type = 'sisu'
        AND sv.qt_inscricao IS NOT NULL
      ORDER BY sv.qt_inscricao::integer DESC
      LIMIT 1
    ) sv_prev_inscricao ON true
    LEFT JOIN LATERAL (
      SELECT
        CASE WHEN count(sv.qt_inscricao) = 0 THEN NULL::boolean
             ELSE bool_or(replace(sv.qt_vagas_ofertadas, '.', '')::integer > sv.qt_inscricao::integer)
        END AS has_vagas_ociosas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.opportunity_type = 'sisu' AND op.year = p.cycle_year
        AND sv.qt_inscricao IS NOT NULL AND sv.qt_vagas_ofertadas IS NOT NULL
    ) vc_curr ON true
    LEFT JOIN LATERAL (
      SELECT
        CASE WHEN count(sv.qt_inscricao) = 0 THEN NULL::boolean
             ELSE bool_or(replace(sv.qt_vagas_ofertadas, '.', '')::integer > sv.qt_inscricao::integer)
        END AS has_vagas_ociosas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.opportunity_type = 'sisu' AND op.year = p.cycle_year - 1
        AND sv.qt_inscricao IS NOT NULL AND sv.qt_vagas_ofertadas IS NOT NULL
    ) vc_prev ON true
    LEFT JOIN public.institutions_info_emec ie  ON ie.institution_id = i.id
    LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
  WHERE o.opportunity_type = 'sisu' AND o.year = p.cycle_year AND o.semester = p.cycle_semester
  ORDER BY c.id, o.created_at
) sisu_branch

UNION ALL

SELECT prouni_branch.* FROM (
  SELECT DISTINCT ON (c.id)
    ('mec_'::text || (c.id)::text) AS unified_id,
    c.course_name                  AS title,
    i.name                         AS provider_name,
    'prouni'::text                 AS type,
    'prouni'::text                 AS opportunity_type,
    'grants_scholarships'::text    AS category,
    false                          AS is_partner,
    ((cp.city || ', '::text) || cp.state) AS location,
    (jsonb_build_array('100% Gratuito', o.shift) - 'null'::text) AS badges,
    o.created_at,
    NULL::text     AS external_redirect_url,
    false          AS external_redirect_enabled,
    p.status::text AS status,
    id_dates.start_date AS starts_at,
    id_dates.end_date   AS ends_at,
    NULL::numeric  AS match_score,
    NULL::text     AS institution_cover_url,
    NULL::text     AS nu_vagas_autorizadas,
    i.id           AS institution_id,
    ie.igc         AS institution_igc,
    ie.academic_organization  AS institution_organization,
    ie.administrative_category AS institution_category,
    ie.site        AS institution_site,
    NULL::jsonb    AS eligibility_criteria,
    NULL::jsonb    AS benefits,
    NULL::text     AS brand_color,
    NULL::jsonb    AS weights,
    sis.acronym    AS institution_acronym,
    cp.latitude,
    cp.longitude,
    s_curr.min_cutoff AS min_cutoff_score_current,
    s_prev.min_cutoff AS min_cutoff_score_prev,
    s_curr.max_cutoff AS max_cutoff_score_current,
    s_prev.max_cutoff AS max_cutoff_score_prev,
    -- NOVO: qt_ofertada somada por curso (todas as modalidades)
    pv_curr.qt_vagas_ofertadas AS qt_vagas_ofertadas_current,
    pv_prev.qt_vagas_ofertadas AS qt_vagas_ofertadas_prev,
    NULL::text AS qt_inscricao_current,
    NULL::text AS qt_inscricao_prev,
    NULL::numeric AS nu_media_minima_enem_current,
    NULL::numeric AS nu_media_minima_enem_prev,
    -- NOVO: vagas_ociosas baseado em qt_ofertada > qt_ocupada
    (COALESCE(pv_curr.vagas_ociosas, 0) > 0)::boolean AS vagas_ociosas_current,
    (COALESCE(pv_prev.vagas_ociosas, 0) > 0)::boolean AS vagas_ociosas_prev,
    public.f_unaccent(
      COALESCE(c.course_name, '') || ' ' ||
      COALESCE(i.name, '') || ' ' ||
      COALESCE(cp.city, '') || ' ' ||
      COALESCE(sis.acronym, '')
    ) AS search_text
  FROM public.opportunities o
    JOIN public.programs p ON p.type = 'prouni' AND p.status <> 'inactive'
    JOIN public.courses c      ON c.id = o.course_id
    JOIN public.campus cp      ON cp.id = c.campus_id
    JOIN public.institutions i ON i.id = cp.institution_id
    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'prouni' AND opp.course_id = o.course_id AND opp.year = p.cycle_year
    ) s_curr ON true
    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'prouni' AND opp.course_id = o.course_id AND opp.year = p.cycle_year - 1
    ) s_prev ON true
    LEFT JOIN LATERAL (
      SELECT d.start_date, d.end_date
      FROM public.important_dates d
      WHERE d.type = 'prouni' AND d.controls_opportunity_dates = true
      ORDER BY d.start_date DESC LIMIT 1
    ) id_dates ON true
    -- NOVO: soma qt_ofertada e qt_ocupada em vez de bolsas_ampla/cota
    LEFT JOIN LATERAL (
      SELECT
        sum(pv.qt_ofertada)::text                        AS qt_vagas_ofertadas,
        sum(COALESCE(pv.qt_ofertada,0) - COALESCE(pv.qt_ocupada,0)) AS vagas_ociosas
      FROM public.opportunities_prouni_vacancies pv
      JOIN public.opportunities opp ON opp.id = pv.opportunity_id
      WHERE opp.course_id = o.course_id AND opp.year = p.cycle_year AND opp.opportunity_type = 'prouni'
    ) pv_curr ON true
    LEFT JOIN LATERAL (
      SELECT
        sum(pv.qt_ofertada)::text                        AS qt_vagas_ofertadas,
        sum(COALESCE(pv.qt_ofertada,0) - COALESCE(pv.qt_ocupada,0)) AS vagas_ociosas
      FROM public.opportunities_prouni_vacancies pv
      JOIN public.opportunities opp ON opp.id = pv.opportunity_id
      WHERE opp.course_id = o.course_id AND opp.year = p.cycle_year - 1 AND opp.opportunity_type = 'prouni'
    ) pv_prev ON true
    LEFT JOIN public.institutions_info_emec ie  ON ie.institution_id = i.id
    LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
  WHERE o.opportunity_type = 'prouni' AND o.year = p.cycle_year AND o.semester = p.cycle_semester
  ORDER BY c.id, o.created_at
) prouni_branch

UNION ALL

SELECT
  ('partner_'::text || po.id::text) AS unified_id,
  po.name AS title,
  i.name AS provider_name,
  'partner'::text AS type,
  po.opportunity_type,
  COALESCE(po.category, 'educational_programs'::text) AS category,
  true AS is_partner,
  'Nacional'::text AS location,
  COALESCE(po.eligibility_criteria -> 'badges', '[]'::jsonb) AS badges,
  po.created_at,
  po.external_redirect_config ->> 'url' AS external_redirect_url,
  COALESCE((po.external_redirect_config ->> 'enabled')::boolean, false) AS external_redirect_enabled,
  po.status::text AS status,
  po.starts_at,
  po.ends_at,
  NULL::numeric  AS match_score,
  pi.cover_url   AS institution_cover_url,
  NULL::text     AS nu_vagas_autorizadas,
  i.id           AS institution_id,
  ie.igc         AS institution_igc,
  ie.academic_organization  AS institution_organization,
  ie.administrative_category AS institution_category,
  ie.site        AS institution_site,
  po.eligibility_criteria,
  NULL::jsonb    AS benefits,
  pi.brand_color,
  NULL::jsonb    AS weights,
  sis.acronym    AS institution_acronym,
  NULL::double precision AS latitude,
  NULL::double precision AS longitude,
  NULL::numeric  AS min_cutoff_score_current,
  NULL::numeric  AS min_cutoff_score_prev,
  NULL::numeric  AS max_cutoff_score_current,
  NULL::numeric  AS max_cutoff_score_prev,
  NULL::text     AS qt_vagas_ofertadas_current,
  NULL::text     AS qt_vagas_ofertadas_prev,
  NULL::text     AS qt_inscricao_current,
  NULL::text     AS qt_inscricao_prev,
  NULL::numeric  AS nu_media_minima_enem_current,
  NULL::numeric  AS nu_media_minima_enem_prev,
  NULL::boolean  AS vagas_ociosas_current,
  NULL::boolean  AS vagas_ociosas_prev,
  public.f_unaccent(
    COALESCE(po.name, '') || ' ' ||
    COALESCE(i.name, '')  || ' ' ||
    COALESCE(sis.acronym, '')
  ) AS search_text
FROM public.partner_opportunities po
  JOIN public.institutions i ON i.id = po.institution_id
  LEFT JOIN public.partner_institutions pi ON pi.institution_id = i.id
  LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
  LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
WHERE po.status IN ('incoming', 'opened', 'closed');

GRANT SELECT ON public.v_unified_opportunities TO authenticated, anon, service_role;

CREATE UNIQUE INDEX uq_v_unified_opportunities_id_type
  ON public.v_unified_opportunities (unified_id, type);
CREATE INDEX idx_v_unified_opportunities_institution
  ON public.v_unified_opportunities (institution_id);
CREATE INDEX idx_v_unified_opportunities_search_text
  ON public.v_unified_opportunities USING gin (search_text gin_trgm_ops);

CREATE OR REPLACE FUNCTION public.search_opportunities(p_q text)
RETURNS SETOF public.v_unified_opportunities
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.v_unified_opportunities
  WHERE search_text LIKE '%' || public.f_unaccent(p_q) || '%';
$$;
GRANT EXECUTE ON FUNCTION public.search_opportunities(text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_unified_opportunities_by_distance(
  p_lat double precision, p_long double precision
)
RETURNS TABLE (
  unified_id text, title text, provider_name text, type text,
  opportunity_type text, category text, is_partner boolean, location text,
  badges jsonb, created_at timestamptz, external_redirect_url text,
  external_redirect_enabled boolean, status text, starts_at timestamptz,
  ends_at timestamptz, match_score numeric, institution_cover_url text,
  nu_vagas_autorizadas text, institution_id uuid, institution_igc text,
  institution_organization text, institution_category text, institution_site text,
  eligibility_criteria jsonb, benefits jsonb, brand_color text, weights jsonb,
  institution_acronym text, latitude double precision, longitude double precision,
  min_cutoff_score_current numeric, min_cutoff_score_prev numeric,
  max_cutoff_score_current numeric, max_cutoff_score_prev numeric,
  qt_vagas_ofertadas_current text, qt_vagas_ofertadas_prev text,
  qt_inscricao_current text, qt_inscricao_prev text,
  nu_media_minima_enem_current numeric, nu_media_minima_enem_prev numeric,
  vagas_ociosas_current boolean, vagas_ociosas_prev boolean,
  search_text text, distance_km double precision
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT v.*,
    CASE
      WHEN v.latitude IS NOT NULL AND v.longitude IS NOT NULL
           AND p_lat IS NOT NULL AND p_long IS NOT NULL THEN
        6371.0 * acos(LEAST(1.0, GREATEST(-1.0,
          cos(radians(p_lat)) * cos(radians(v.latitude)) *
          cos(radians(v.longitude) - radians(p_long)) +
          sin(radians(p_lat)) * sin(radians(v.latitude))
        )))
      ELSE NULL
    END AS distance_km
  FROM public.v_unified_opportunities v;
$$;
GRANT EXECUTE ON FUNCTION public.get_unified_opportunities_by_distance(double precision, double precision)
  TO authenticated, anon, service_role;

-- Recreate v_unified_institutions (depends on v_unified_opportunities)
CREATE OR REPLACE VIEW public.v_unified_institutions AS
WITH inst_opps AS (
  SELECT
    v.institution_id,
    array_agg(DISTINCT v.opportunity_type) AS opp_types,
    COUNT(*) FILTER (WHERE v.status = 'opened') AS open_opportunities_count
  FROM public.v_unified_opportunities v
  GROUP BY v.institution_id
)
SELECT
  i.id, i.name,
  COALESCE(pi.location,
    CASE
      WHEN ie.city IS NOT NULL AND ie.state IS NOT NULL THEN (ie.city || ' - ') || ie.state
      WHEN ie.city IS NOT NULL THEN ie.city
      WHEN ie.state IS NOT NULL THEN ie.state
      ELSE (SELECT (c.city || ' - ') || c.state FROM public.campus c WHERE c.institution_id = i.id AND c.city IS NOT NULL LIMIT 1)
    END
  ) AS location,
  pi.logo_url, pi.cover_url, pi.brand_color, pi.description, pi.website_url,
  sisu.acronym,
  CASE WHEN i.is_partner IS TRUE THEN 'partner' ELSE 'mec' END AS type,
  i.is_partner AS is_partner,
  io.opp_types,
  COALESCE(io.open_opportunities_count, 0) AS open_opportunities_count,
  (COALESCE(io.open_opportunities_count, 0) > 0) AS has_open_opportunities,
  COALESCE(sisu.academic_organization,  ie.academic_organization)  AS academic_organization,
  COALESCE(sisu.administrative_category, ie.administrative_category) AS administrative_category,
  CASE WHEN i.is_partner IS TRUE THEN NULL ELSE ie.igc END AS igc,
  CASE WHEN i.is_partner IS TRUE THEN NULL ELSE ie.ci END AS ci,
  CASE WHEN i.is_partner IS TRUE THEN NULL ELSE ie.ci_ead END AS ci_ead,
  CASE WHEN i.is_partner IS TRUE THEN NULL ELSE ie.legal_nature END AS legal_nature,
  CASE WHEN i.is_partner IS TRUE THEN NULL ELSE ie.maintainer_name END AS maintainer_name
FROM public.institutions i
  LEFT JOIN public.partner_institutions pi  ON pi.institution_id = i.id
  LEFT JOIN public.institutions_info_emec ie   ON ie.institution_id = i.id
  LEFT JOIN public.institutions_info_sisu sisu ON sisu.institution_id = i.id
  LEFT JOIN inst_opps io ON io.institution_id = i.id;

GRANT SELECT ON public.v_unified_institutions TO anon, authenticated, service_role;

REFRESH MATERIALIZED VIEW public.v_unified_opportunities;

-- ====================================================================================
-- 7. Rebuild calculate_match — remove referencias a bolsas_ampla/cota
--    has_vagas_ociosas: pv.qt_ofertada > pv.qt_ocupada
--    cota_eligible ProUni: concurrency_type IN ('COTA', 'COTA_PPI', 'COTA_PCD')
--                          e usuario tem quota compatível
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.calculate_match(p_profile_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_income                NUMERIC;
    v_course_interests      TEXT[];
    v_preferred_shifts      TEXT[];
    v_university_preference TEXT;
    v_program_preference    TEXT;
    v_state_preference      TEXT;
    v_location_preference   TEXT;
    v_lat                   NUMERIC;
    v_lon                   NUMERIC;
    v_quota_types           TEXT[];

    v_nota_linguagens        NUMERIC;
    v_nota_ciencias_humanas  NUMERIC;
    v_nota_ciencias_natureza NUMERIC;
    v_nota_matematica        NUMERIC;
    v_nota_redacao           NUMERIC;
    v_enem_avg               NUMERIC;
    v_has_enem               BOOLEAN := false;
    v_is_treineiro_score     BOOLEAN := false;

    v_weights              JSONB;
    v_enem_window_sisu     INT     := 3;
    v_salario_minimo       NUMERIC := 1621.00;
    v_has_funnel_filters   BOOLEAN;

    v_sisu_year       INT;
    v_sisu_semester   TEXT;
    v_prouni_year     INT;
    v_prouni_semester TEXT;

    v_course_group_courses TEXT[];
    v_academic_floor       NUMERIC := 50.0;
    v_user_tags             TEXT[] := '{}';
    v_pref_city_lat        NUMERIC;
    v_pref_city_lon        NUMERIC;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext(p_profile_id::text));

    SELECT cycle_year, cycle_semester INTO v_sisu_year, v_sisu_semester
    FROM public.programs WHERE LOWER(type) = 'sisu' AND status <> 'inactive'
    ORDER BY cycle_year DESC, cycle_semester DESC LIMIT 1;

    SELECT cycle_year, cycle_semester INTO v_prouni_year, v_prouni_semester
    FROM public.programs WHERE LOWER(type) = 'prouni' AND status <> 'inactive'
    ORDER BY cycle_year DESC, cycle_semester DESC LIMIT 1;

    IF v_sisu_year IS NULL    THEN v_sisu_year := 2025;    v_sisu_semester := '1'; END IF;
    IF v_prouni_year IS NULL  THEN v_prouni_year := 2025;  v_prouni_semester := '1'; END IF;

    SELECT
        up.family_income_per_capita, up.course_interest, up.preferred_shifts,
        up.university_preference, up.program_preference, up.state_preference,
        up.location_preference, up.device_latitude, up.device_longitude, up.quota_types
    INTO
        v_income, v_course_interests, v_preferred_shifts,
        v_university_preference, v_program_preference, v_state_preference,
        v_location_preference, v_lat, v_lon, v_quota_types
    FROM public.user_preferences up WHERE up.user_id = p_profile_id;

    v_user_tags := COALESCE(v_quota_types, '{}'::TEXT[]) || ARRAY['SEM_CRITERIO_RENDA', 'AMPLA_CONCORRENCIA'];

    IF v_income IS NOT NULL THEN
        IF v_income <= v_salario_minimo * 1.0 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_1_SM', 'RENDA_ATE_1_5_SM', 'RENDA_ATE_2_SM', 'RENDA_ATE_4_SM', 'BAIXA_RENDA'];
        ELSIF v_income <= v_salario_minimo * 1.5 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_1_5_SM', 'RENDA_ATE_2_SM', 'RENDA_ATE_4_SM', 'BAIXA_RENDA'];
        ELSIF v_income <= v_salario_minimo * 2.0 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_2_SM', 'RENDA_ATE_4_SM', 'BAIXA_RENDA'];
        ELSIF v_income <= v_salario_minimo * 4.0 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_4_SM'];
        END IF;
    END IF;

    SELECT nota_linguagens, nota_ciencias_humanas, nota_ciencias_natureza, nota_matematica, nota_redacao
    INTO v_nota_linguagens, v_nota_ciencias_humanas, v_nota_ciencias_natureza, v_nota_matematica, v_nota_redacao
    FROM public.user_enem_scores WHERE user_id = p_profile_id ORDER BY year DESC LIMIT 1;

    IF v_nota_linguagens IS NOT NULL THEN
        v_has_enem := true;
        v_enem_avg := (COALESCE(v_nota_linguagens,0)+COALESCE(v_nota_ciencias_humanas,0)+
                       COALESCE(v_nota_ciencias_natureza,0)+COALESCE(v_nota_matematica,0)+
                       COALESCE(v_nota_redacao,0)) / 5.0;
        IF (SELECT is_treineiro FROM public.user_enem_scores WHERE user_id = p_profile_id ORDER BY year DESC LIMIT 1) THEN
            v_is_treineiro_score := true;
        END IF;
    END IF;

    SELECT weights INTO v_weights FROM public.match_config ORDER BY created_at DESC LIMIT 1;

    SELECT
        (v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0)
     OR (v_preferred_shifts  IS NOT NULL AND cardinality(v_preferred_shifts) > 0)
     OR v_state_preference IS NOT NULL
     OR v_program_preference IS NOT NULL
    INTO v_has_funnel_filters;

    IF v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0 THEN
        SELECT array_agg(UPPER(cn)) INTO v_course_group_courses
        FROM public.course_groups cg, unnest(cg.course_names) AS cn
        WHERE EXISTS (
            SELECT 1 FROM unnest(v_course_interests) ci
            WHERE cg.course_names && ARRAY[ci]
        );
    END IF;

    IF v_lat IS NOT NULL AND v_lon IS NOT NULL AND v_location_preference IS NOT NULL THEN
        SELECT c.latitude, c.longitude INTO v_pref_city_lat, v_pref_city_lon
        FROM public.cities c
        WHERE public.f_unaccent(lower(c.name)) ILIKE '%' || public.f_unaccent(lower(v_location_preference)) || '%'
        ORDER BY c.population DESC NULLS LAST LIMIT 1;
        IF v_pref_city_lat IS NOT NULL THEN
            v_lat := v_pref_city_lat; v_lon := v_pref_city_lon;
        END IF;
    END IF;

    DELETE FROM public.user_opportunity_matches WHERE profile_id = p_profile_id;

    CREATE TEMP TABLE _mec_funnel (
        opp_id uuid, unified_id text, course_id uuid, course_name text,
        opportunity_type text, scholarship_type text, concurrency_type text, concurrency_tags jsonb,
        cutoff_score numeric, shift text, is_partner boolean,
        campus_lat numeric, campus_lon numeric, campus_state text, campus_city text,
        institution_id uuid,
        peso_linguagens text, peso_ciencias_humanas text, peso_ciencias_natureza text,
        peso_matematica text, peso_redacao text,
        has_vagas_ociosas boolean,
        eligibility_criteria jsonb
    ) ON COMMIT DROP;

    IF v_has_funnel_filters THEN
        INSERT INTO _mec_funnel
        SELECT o.id, 'mec_'||c.id::text, o.course_id, c.course_name,
               o.opportunity_type, o.scholarship_type, o.concurrency_type, o.concurrency_tags,
               o.cutoff_score, o.shift, false,
               cp.latitude, cp.longitude, cp.state, cp.city, i.id,
               sv.peso_linguagens, sv.peso_ciencias_humanas, sv.peso_ciencias_natureza,
               sv.peso_matematica, sv.peso_redacao,
               false,
               NULL::jsonb
        FROM public.opportunities o
        JOIN public.courses c      ON c.id = o.course_id
        JOIN public.campus cp      ON cp.id = c.campus_id
        JOIN public.institutions i ON i.id = cp.institution_id
        LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
        WHERE (
            (o.opportunity_type = 'sisu'   AND o.year = v_sisu_year   AND o.semester = v_sisu_semester) OR
            (o.opportunity_type = 'prouni' AND o.year = v_prouni_year AND o.semester = v_prouni_semester)
        )
          AND (v_program_preference IS NULL OR v_program_preference = 'indiferente'
               OR o.opportunity_type = v_program_preference)
          AND (
              v_course_interests IS NULL OR cardinality(v_course_interests) = 0
              OR EXISTS (SELECT 1 FROM unnest(v_course_interests) ci WHERE c.course_name ILIKE '%'||ci||'%')
              OR (v_course_group_courses IS NOT NULL AND UPPER(c.course_name) = ANY(v_course_group_courses))
          )
          AND (v_state_preference IS NULL OR cp.state = v_state_preference)
          AND (v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts) = 0
               OR o.shift = ANY(v_preferred_shifts))
        ORDER BY
          (CASE
             WHEN v_course_interests IS NULL OR cardinality(v_course_interests) = 0 THEN 1
             WHEN EXISTS (SELECT 1 FROM unnest(v_course_interests) ci WHERE c.course_name ILIKE '%'||ci||'%') THEN 0
             WHEN v_course_group_courses IS NOT NULL AND UPPER(c.course_name) = ANY(v_course_group_courses) THEN 0
             ELSE 1
           END) ASC,
          (CASE
             WHEN v_lat IS NOT NULL AND v_lon IS NOT NULL AND cp.latitude IS NOT NULL AND cp.longitude IS NOT NULL
               THEN public.haversine_km(v_lat, v_lon, cp.latitude, cp.longitude)
             ELSE 999999
           END) ASC
        LIMIT 1500;

    ELSIF v_lat IS NOT NULL AND v_lon IS NOT NULL THEN
        INSERT INTO _mec_funnel
        SELECT o.id, 'mec_'||c.id::text, o.course_id, c.course_name,
               o.opportunity_type, o.scholarship_type, o.concurrency_type, o.concurrency_tags,
               o.cutoff_score, o.shift, false,
               cp.latitude, cp.longitude, cp.state, cp.city, i.id,
               sv.peso_linguagens, sv.peso_ciencias_humanas, sv.peso_ciencias_natureza,
               sv.peso_matematica, sv.peso_redacao,
               false,
               NULL::jsonb
        FROM public.opportunities o
        JOIN public.courses c      ON c.id = o.course_id
        JOIN public.campus cp      ON cp.id = c.campus_id
        JOIN public.institutions i ON i.id = cp.institution_id
        LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
        WHERE (
            (o.opportunity_type = 'sisu'   AND o.year = v_sisu_year   AND o.semester = v_sisu_semester) OR
            (o.opportunity_type = 'prouni' AND o.year = v_prouni_year AND o.semester = v_prouni_semester)
        )
          AND cp.latitude IS NOT NULL AND cp.longitude IS NOT NULL
          AND cp.latitude BETWEEN (v_lat - 4.5) AND (v_lat + 4.5)
          AND cp.longitude BETWEEN (v_lon - 5.5) AND (v_lon + 5.5)
          AND public.haversine_km(v_lat, v_lon, cp.latitude, cp.longitude) <= 500
        ORDER BY public.haversine_km(v_lat, v_lon, cp.latitude, cp.longitude) ASC
        LIMIT 1500;

    ELSE
        INSERT INTO _mec_funnel
        SELECT o.id, 'mec_'||c.id::text, o.course_id, c.course_name,
               o.opportunity_type, o.scholarship_type, o.concurrency_type, o.concurrency_tags,
               o.cutoff_score, o.shift, false,
               cp.latitude, cp.longitude, cp.state, cp.city, i.id,
               sv.peso_linguagens, sv.peso_ciencias_humanas, sv.peso_ciencias_natureza,
               sv.peso_matematica, sv.peso_redacao,
               false,
               NULL::jsonb
        FROM public.opportunities o
        JOIN public.courses c      ON c.id = o.course_id
        JOIN public.campus cp      ON cp.id = c.campus_id
        JOIN public.institutions i ON i.id = cp.institution_id
        LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
        WHERE (
            (o.opportunity_type = 'sisu'   AND o.year = v_sisu_year   AND o.semester = v_sisu_semester) OR
            (o.opportunity_type = 'prouni' AND o.year = v_prouni_year AND o.semester = v_prouni_semester)
        )
        ORDER BY hashtext(c.id::text || p_profile_id::text)
        LIMIT 1000;
    END IF;

    -- has_vagas_ociosas:
    --   SiSU: qt_vagas_ofertadas > qt_inscricao (lógica existente)
    --   ProUni: pv.qt_ofertada > pv.qt_ocupada  ← NOVO (sem bolsas_ampla/cota)
    UPDATE _mec_funnel m
    SET has_vagas_ociosas = true
    WHERE EXISTS (
        SELECT 1 FROM public.opportunities_sisu_vacancies sv2
        WHERE sv2.opportunity_id = m.opp_id
          AND sv2.qt_vagas_ofertadas IS NOT NULL
          AND sv2.qt_inscricao IS NOT NULL
          AND replace(sv2.qt_vagas_ofertadas, '.', '')::int > sv2.qt_inscricao::int
    ) OR EXISTS (
        -- ProUni: vagas ociosas = ofertadas > ocupadas por oportunidade (concurrency_type-aware)
        SELECT 1 FROM public.opportunities_prouni_vacancies pv2
        WHERE pv2.opportunity_id = m.opp_id
          AND COALESCE(pv2.qt_ofertada, 0) > COALESCE(pv2.qt_ocupada, 0)
    );

    INSERT INTO public.user_opportunity_matches
        (profile_id, unified_opportunity_id, match_score, match_details)

    WITH

    all_opportunities AS (
        SELECT * FROM _mec_funnel
        UNION ALL
        SELECT po.id, 'partner_'||po.id::text, NULL::uuid, po.name,
               'partner', NULL, NULL, NULL::jsonb, NULL::numeric, NULL,
               true, NULL::numeric, NULL::numeric, NULL, NULL,
               po.institution_id, NULL, NULL, NULL, NULL, NULL, false::boolean,
               po.eligibility_criteria
        FROM public.partner_opportunities po
        WHERE po.status::text IN ('approved', 'incoming', 'opened')
    ),

    scored_performance AS (
        SELECT
            ao.*,
            CASE
                WHEN ao.opportunity_type = 'prouni' AND ao.scholarship_type ILIKE '%Integral%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 1.5 THEN false
                WHEN ao.opportunity_type = 'prouni' AND ao.scholarship_type ILIKE '%Parcial%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 3.0 THEN false
                WHEN ao.opportunity_type = 'sisu' AND ao.concurrency_type ILIKE '%renda%'
                     AND NOT EXISTS (
                         SELECT 1 FROM jsonb_array_elements(ao.concurrency_tags) AS ts
                         WHERE ts ? 'SEM_CRITERIO_RENDA'
                     )
                     AND ao.concurrency_type NOT ILIKE '%independentemente%da%renda%'
                     AND ao.concurrency_type NOT ILIKE '%independentemente%de%renda%'
                     AND ao.concurrency_type NOT ILIKE '%independente%da%renda%'
                     AND ao.concurrency_type NOT ILIKE '%independente%de%renda%'
                     AND ao.concurrency_type NOT ILIKE '%qualquer%renda%'
                     AND ao.concurrency_type NOT ILIKE '%sem%critério%de%renda%'
                     AND ao.concurrency_type NOT ILIKE '%não%declarem%ser%oriundos%de%famílias%com%renda%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 1.5 THEN false
                ELSE true
            END AS meets_income,
            CASE
                -- ProUni NOVO: cota_eligible baseado em concurrency_type da oportunidade
                --   AMPLA → nunca elegível por cota
                --   COTA_PPI / COTA → elegível se usuário tem PPI ou INDIGENAS
                --   COTA_PCD → elegível se usuário tem PCD
                WHEN ao.opportunity_type = 'prouni' THEN
                    CASE
                        WHEN ao.concurrency_type = 'AMPLA' THEN false
                        WHEN ao.concurrency_type IN ('COTA_PPI', 'COTA') THEN
                            COALESCE(v_quota_types, '{}'::text[]) && ARRAY['PPI','INDIGENAS']
                        WHEN ao.concurrency_type = 'COTA_PCD' THEN
                            COALESCE(v_quota_types, '{}'::text[]) && ARRAY['PCD']
                        ELSE false
                    END
                WHEN ao.concurrency_tags IS NULL OR jsonb_array_length(ao.concurrency_tags) = 0 THEN false
                WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(ao.concurrency_tags) AS tag_set
                    WHERE NOT (
                        jsonb_array_length(tag_set) = 1 AND tag_set->>0 = 'AMPLA_CONCORRENCIA'
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(tag_set) AS tag
                        WHERE NOT (tag = ANY(v_user_tags))
                    )
                ) THEN true
                ELSE false
            END AS cota_eligible,
            CASE
                WHEN v_has_enem AND ao.peso_linguagens IS NOT NULL THEN
                    (COALESCE(v_nota_linguagens,0)*COALESCE(ao.peso_linguagens::numeric,1)+
                     COALESCE(v_nota_ciencias_humanas,0)*COALESCE(ao.peso_ciencias_humanas::numeric,1)+
                     COALESCE(v_nota_ciencias_natureza,0)*COALESCE(ao.peso_ciencias_natureza::numeric,1)+
                     COALESCE(v_nota_matematica,0)*COALESCE(ao.peso_matematica::numeric,1)+
                     COALESCE(v_nota_redacao,0)*COALESCE(ao.peso_redacao::numeric,1))
                    / NULLIF(COALESCE(ao.peso_linguagens::numeric,1)+COALESCE(ao.peso_ciencias_humanas::numeric,1)+
                             COALESCE(ao.peso_ciencias_natureza::numeric,1)+COALESCE(ao.peso_matematica::numeric,1)+
                             COALESCE(ao.peso_redacao::numeric,1), 0)
                WHEN v_has_enem THEN v_enem_avg
                ELSE NULL
            END AS weighted_enem_score
        FROM all_opportunities ao
    ),

    scored_academic AS (
        SELECT sp.*,
            CASE
                WHEN sp.is_partner THEN NULL
                WHEN sp.weighted_enem_score IS NOT NULL AND sp.cutoff_score IS NOT NULL AND sp.cutoff_score > 0 THEN
                    GREATEST(v_academic_floor, LEAST(100.0,
                        (100.0 - CASE
                            WHEN sp.weighted_enem_score >= sp.cutoff_score THEN
                                (sp.weighted_enem_score - sp.cutoff_score) * COALESCE((v_weights->>'score_decay_above_cutoff')::NUMERIC, 0.3)
                            ELSE
                                (sp.cutoff_score - sp.weighted_enem_score) * COALESCE((v_weights->>'score_decay_below_cutoff')::NUMERIC, 0.9)
                         END)
                        * CASE WHEN v_is_treineiro_score THEN 0.85 ELSE 1.0 END))
                ELSE v_academic_floor
            END AS academic_score
        FROM scored_performance sp
    ),

    scored_preferences AS (
        SELECT sa.*,
            CASE WHEN v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts)=0 THEN 50.0
                 WHEN sa.shift IS NULL THEN 50.0
                 WHEN sa.shift = ANY(v_preferred_shifts) THEN 100.0
                 ELSE 0.0 END AS shift_score,
            CASE WHEN v_university_preference IS NULL OR v_university_preference='indiferente' THEN 50.0
                 WHEN v_university_preference='publica'  AND sa.opportunity_type='sisu'               THEN 100.0
                 WHEN v_university_preference='privada'  AND sa.opportunity_type IN ('prouni','partner') THEN 100.0
                 ELSE 20.0 END
            + CASE WHEN v_program_preference IS NULL OR v_program_preference='indiferente' THEN 50.0
                   WHEN v_program_preference='sisu'   AND sa.opportunity_type='sisu'   THEN 100.0
                   WHEN v_program_preference='prouni' AND sa.opportunity_type='prouni' THEN 100.0
                   ELSE 20.0 END AS inst_program_score_raw,
            CASE
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                                 WHERE LOWER(sa.course_name) = LOWER(ci)) THEN 100.0
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                                 WHERE sa.course_name ILIKE '%'||ci||'%') THEN 85.0
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND v_course_group_courses IS NOT NULL
                     AND UPPER(sa.course_name) = ANY(v_course_group_courses) THEN 70.0
                WHEN v_course_interests IS NULL OR cardinality(v_course_interests) = 0 THEN 50.0
                ELSE 10.0
            END AS course_score
        FROM scored_academic sa
    ),

    scored_location AS (
        SELECT sp.*,
            LEAST(100.0, sp.inst_program_score_raw/2.0) AS inst_program_score,
            CASE
                WHEN v_lat IS NOT NULL AND v_lon IS NOT NULL
                     AND sp.campus_lat IS NOT NULL AND sp.campus_lon IS NOT NULL THEN
                    GREATEST(0.0, 100.0 - public.haversine_km(v_lat, v_lon, sp.campus_lat, sp.campus_lon)*0.5)
                ELSE 40.0
            END AS distance_score,
            CASE WHEN v_state_preference IS NOT NULL AND sp.campus_state IS NOT NULL
                      AND LOWER(sp.campus_state)=LOWER(v_state_preference) THEN 30.0
                 WHEN v_location_preference IS NOT NULL AND sp.campus_city IS NOT NULL
                      AND LOWER(sp.campus_city) ILIKE '%'||LOWER(v_location_preference)||'%' THEN 30.0
                 ELSE 0.0 END AS regional_bonus
        FROM scored_preferences sp
    ),

    composite AS (
        SELECT sl.opp_id, sl.concurrency_type, sl.concurrency_tags,
               sl.unified_id, sl.course_id, sl.is_partner, sl.meets_income, sl.cota_eligible,
               sl.academic_score, sl.shift_score, sl.inst_program_score, sl.course_score,
               sl.distance_score, sl.regional_bonus, sl.weighted_enem_score, sl.cutoff_score,
               sl.has_vagas_ociosas, sl.opportunity_type,
               pe.elig AS partner_elig,
               CASE
                   WHEN sl.is_partner THEN COALESCE((pe.elig->>'score')::numeric, 100.0)
                   WHEN NOT sl.meets_income THEN 0.0
                   WHEN sl.opportunity_type = 'prouni'
                        AND sl.weighted_enem_score IS NOT NULL
                        AND sl.weighted_enem_score < 450 THEN 0.0
                   ELSE LEAST(100.0, GREATEST(0.0,
                       (
                         (CASE WHEN sl.cutoff_score IS NULL THEN 0.0
                               ELSE COALESCE((v_weights->>'performance_weight')::NUMERIC,0.40) END) * sl.academic_score
                         + COALESCE((v_weights->>'preference_weight')::NUMERIC,0.30) * (
                             sl.shift_score*0.333 + sl.inst_program_score*0.333 + sl.course_score*0.334)
                         + COALESCE((v_weights->>'location_weight')::NUMERIC,0.20) * (
                             LEAST(100.0, sl.distance_score + sl.regional_bonus))
                       ) / NULLIF(
                         (CASE WHEN sl.cutoff_score IS NULL THEN 0.0
                               ELSE COALESCE((v_weights->>'performance_weight')::NUMERIC,0.40) END)
                         + COALESCE((v_weights->>'preference_weight')::NUMERIC,0.30)
                         + COALESCE((v_weights->>'location_weight')::NUMERIC,0.20), 0)
                   ))
               END AS base_score
        FROM scored_location sl
        LEFT JOIN LATERAL (
            SELECT public.evaluate_partner_eligibility(p_profile_id, sl.opp_id) AS elig
            WHERE sl.is_partner
        ) pe ON true
    ),

    boosted AS (
        SELECT c.*,
            CASE
                WHEN c.is_partner THEN
                    LEAST(c.base_score*COALESCE((v_weights->>'partner_boost')::NUMERIC,1.15),
                          c.base_score+COALESCE((v_weights->>'partner_boost_cap')::NUMERIC,20.0))
                WHEN NOT c.meets_income THEN 0.0
                WHEN c.base_score <= 0.0 THEN 0.0
                ELSE c.base_score
                     + CASE WHEN c.has_vagas_ociosas THEN COALESCE((v_weights->>'idle_vacancy_boost')::NUMERIC, 5.0) ELSE 0.0 END
                     + CASE WHEN c.cota_eligible     THEN COALESCE((v_weights->>'cota_bonus')::NUMERIC,10.0)        ELSE 0.0 END
            END AS final_score,
            jsonb_build_object(
                'score_basis', CASE WHEN c.is_partner THEN 'eligibility' ELSE 'academic' END,
                'partner_eligibility', c.partner_elig,
                'meets_income', c.meets_income, 'cota_eligible', c.cota_eligible,
                'treineiro_score', v_is_treineiro_score,
                'academic_score', round(c.academic_score,2),
                'weighted_enem_score', round(COALESCE(c.weighted_enem_score,0),2),
                'cutoff_score', COALESCE(c.cutoff_score,0),
                'shift_score', round(c.shift_score,2),
                'inst_program_score', round(c.inst_program_score,2),
                'course_score', round(c.course_score,2),
                'distance_score', round(c.distance_score,2),
                'regional_bonus', round(c.regional_bonus,2),
                'base_score', round(c.base_score,2),
                'is_partner', c.is_partner,
                'boost_applied', c.is_partner,
                'idle_vacancy_boost_applied', c.has_vagas_ociosas AND NOT c.is_partner,
                'cota_bonus_applied', (c.cota_eligible AND c.meets_income AND NOT c.is_partner),
                'opportunity_type', c.opportunity_type,
                'best_opportunity_id', c.opp_id,
                'best_concurrency_type', c.concurrency_type,
                'best_concurrency_tags', c.concurrency_tags,
                'cycle', jsonb_build_object('sisu_year',v_sisu_year,'sisu_semester',v_sisu_semester,
                                             'prouni_year',v_prouni_year,'prouni_semester',v_prouni_semester)
            ) AS details
        FROM composite c
    ),

    course_best AS (
        SELECT DISTINCT ON (COALESCE(b.course_id::text, b.unified_id))
            b.unified_id, b.is_partner,
            LEAST(100.0, round(b.final_score,2)) AS final_score,
            b.details
        FROM boosted b
        ORDER BY COALESCE(b.course_id::text, b.unified_id), b.final_score DESC
    ),

    mec_top100 AS (
        SELECT unified_id, is_partner, final_score, details
        FROM course_best WHERE NOT is_partner
        ORDER BY final_score DESC LIMIT 100
    ),

    partners_all AS (
        SELECT unified_id, is_partner, final_score, details
        FROM course_best WHERE is_partner
    )

    SELECT p_profile_id, unified_id, final_score, details FROM mec_top100
    UNION ALL
    SELECT p_profile_id, unified_id, final_score, details FROM partners_all;

END;
$function$;
