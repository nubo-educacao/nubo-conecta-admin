-- 20260609172116_prouni_independent_and_unified_view_fix.sql
-- Fixes v_unified_opportunities to dynamically find the prev cycle.
-- Makes etl_import_prouni_vacancies independent (creates Inst, Campus, Courses).

DROP MATERIALIZED VIEW IF EXISTS public.mv_course_catalog CASCADE;
DROP VIEW IF EXISTS public.v_unified_institutions CASCADE;
DROP FUNCTION IF EXISTS public.get_unified_opportunities_by_distance(double precision, double precision) CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.v_unified_opportunities CASCADE;

CREATE MATERIALIZED VIEW public.v_unified_opportunities AS

-- ─────────── SISU ───────────
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
    sv_curr.qt_inscricao AS qt_inscricao_current,
    sv_prev_inscricao.qt_inscricao AS qt_inscricao_prev,
    vc_curr.has_vagas_ociosas AS vagas_ociosas_current,
    vc_prev.has_vagas_ociosas AS vagas_ociosas_prev

  FROM public.opportunities o
    JOIN public.programs p
        ON p.type = 'sisu'::text AND p.status <> 'inactive'::text
    JOIN public.courses c         ON c.id = o.course_id
    JOIN public.campus cp         ON cp.id = c.campus_id
    JOIN public.institutions i    ON i.id = cp.institution_id

    -- FIND PREV PROGRAM DYNAMICALLY
    LEFT JOIN LATERAL (
      SELECT prev_p.cycle_year, prev_p.cycle_semester
      FROM public.programs prev_p
      WHERE prev_p.type = 'sisu' 
        AND prev_p.status <> 'inactive'
        AND (
          prev_p.cycle_year < p.cycle_year 
          OR (prev_p.cycle_year = p.cycle_year AND prev_p.cycle_semester < p.cycle_semester)
        )
      ORDER BY prev_p.cycle_year DESC, prev_p.cycle_semester DESC
      LIMIT 1
    ) prev_program ON true

    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'sisu' AND opp.course_id = o.course_id AND opp.year = p.cycle_year
    ) s_curr ON true

    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'sisu' AND opp.course_id = o.course_id 
        AND opp.year = prev_program.cycle_year AND opp.semester = prev_program.cycle_semester
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
      SELECT sv.qt_vagas_ofertadas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id 
        AND op.year = prev_program.cycle_year AND op.semester = prev_program.cycle_semester
        AND op.opportunity_type = 'sisu'
      LIMIT 1
    ) sv_prev ON true

    LEFT JOIN LATERAL (
      SELECT sv.qt_inscricao
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id 
        AND op.year = prev_program.cycle_year AND op.semester = prev_program.cycle_semester
        AND op.opportunity_type = 'sisu'
        AND sv.qt_inscricao IS NOT NULL
      ORDER BY sv.qt_inscricao::integer DESC
      LIMIT 1
    ) sv_prev_inscricao ON true

    LEFT JOIN LATERAL (
      SELECT CASE WHEN COUNT(sv.qt_inscricao) = 0 THEN NULL ELSE bool_or(replace(sv.qt_vagas_ofertadas, '.', '')::integer > sv.qt_inscricao::integer) END AS has_vagas_ociosas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.opportunity_type = 'sisu' AND op.year = p.cycle_year AND sv.qt_inscricao IS NOT NULL AND sv.qt_vagas_ofertadas IS NOT NULL
    ) vc_curr ON true

    LEFT JOIN LATERAL (
      SELECT CASE WHEN COUNT(sv.qt_inscricao) = 0 THEN NULL ELSE bool_or(replace(sv.qt_vagas_ofertadas, '.', '')::integer > sv.qt_inscricao::integer) END AS has_vagas_ociosas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.opportunity_type = 'sisu' 
        AND op.year = prev_program.cycle_year AND op.semester = prev_program.cycle_semester
        AND sv.qt_inscricao IS NOT NULL AND sv.qt_vagas_ofertadas IS NOT NULL
    ) vc_prev ON true

    LEFT JOIN public.institutions_info_emec ie  ON ie.institution_id = i.id
    LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id

  WHERE o.opportunity_type = 'sisu' AND o.year = p.cycle_year AND o.semester = p.cycle_semester
  ORDER BY c.id, o.created_at
) sisu_branch

UNION ALL

-- ─────────── PROUNI ───────────
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
    pv_curr.qt_vagas_ofertadas AS qt_vagas_ofertadas_current,
    pv_prev.qt_vagas_ofertadas AS qt_vagas_ofertadas_prev,
    NULL::text AS qt_inscricao_current,
    NULL::text AS qt_inscricao_prev,
    (COALESCE(pv_curr.vagas_ociosas, 0) > 0)::boolean AS vagas_ociosas_current,
    (COALESCE(pv_prev.vagas_ociosas, 0) > 0)::boolean AS vagas_ociosas_prev

  FROM public.opportunities o
    JOIN public.programs p ON p.type = 'prouni' AND p.status <> 'inactive'
    JOIN public.courses c      ON c.id = o.course_id
    JOIN public.campus cp      ON cp.id = c.campus_id
    JOIN public.institutions i ON i.id = cp.institution_id

    -- FIND PREV PROGRAM DYNAMICALLY
    LEFT JOIN LATERAL (
      SELECT prev_p.cycle_year, prev_p.cycle_semester
      FROM public.programs prev_p
      WHERE prev_p.type = 'prouni' 
        AND prev_p.status <> 'inactive'
        AND (
          prev_p.cycle_year < p.cycle_year 
          OR (prev_p.cycle_year = p.cycle_year AND prev_p.cycle_semester < p.cycle_semester)
        )
      ORDER BY prev_p.cycle_year DESC, prev_p.cycle_semester DESC
      LIMIT 1
    ) prev_program ON true

    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'prouni' AND opp.course_id = o.course_id AND opp.year = p.cycle_year
    ) s_curr ON true

    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'prouni' AND opp.course_id = o.course_id 
        AND opp.year = prev_program.cycle_year AND opp.semester = prev_program.cycle_semester
    ) s_prev ON true

    LEFT JOIN LATERAL (
      SELECT d.start_date, d.end_date
      FROM public.important_dates d
      WHERE d.type = 'prouni' AND d.controls_opportunity_dates = true
      ORDER BY d.start_date DESC LIMIT 1
    ) id_dates ON true

    LEFT JOIN LATERAL (
      SELECT sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
             sum((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada)) AS vagas_ociosas
      FROM public.courses_prouni_vacancies pv
      WHERE pv.course_id = o.course_id AND pv.year = p.cycle_year
    ) pv_curr ON true

    LEFT JOIN LATERAL (
      SELECT sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
             sum((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada)) AS vagas_ociosas
      FROM public.courses_prouni_vacancies pv
      WHERE pv.course_id = o.course_id 
        AND pv.year = prev_program.cycle_year AND pv.semester = prev_program.cycle_semester
    ) pv_prev ON true

    LEFT JOIN public.institutions_info_emec ie  ON ie.institution_id = i.id
    LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id

  WHERE o.opportunity_type = 'prouni' AND o.year = p.cycle_year AND o.semester = p.cycle_semester
  ORDER BY c.id, o.created_at
) prouni_branch

UNION ALL

-- ─────────── PARTNER ───────────
SELECT
  ('partner_'::text || (po.id)::text) AS unified_id,
  po.name                             AS title,
  i.name                              AS provider_name,
  'partner'::text                     AS type,
  po.opportunity_type,
  'educational_programs'::text        AS category,
  true                                AS is_partner,
  'Nacional'::text                    AS location,
  COALESCE(po.eligibility_criteria->'badges'::text, '[]'::jsonb) AS badges,
  po.created_at,
  (po.external_redirect_config->>'url')                   AS external_redirect_url,
  COALESCE(((po.external_redirect_config->>'enabled'))::boolean, false) AS external_redirect_enabled,
  (po.status)::text                   AS status,
  po.starts_at,
  po.ends_at,
  NULL::numeric   AS match_score,
  pi.cover_url    AS institution_cover_url,
  NULL::text      AS nu_vagas_autorizadas,
  i.id            AS institution_id,
  ie.igc          AS institution_igc,
  ie.academic_organization  AS institution_organization,
  ie.administrative_category AS institution_category,
  ie.site         AS institution_site,
  po.eligibility_criteria,
  NULL::jsonb     AS benefits,
  pi.brand_color,
  NULL::jsonb     AS weights,
  sis.acronym     AS institution_acronym,
  NULL::double precision AS latitude,
  NULL::double precision AS longitude,
  NULL::numeric   AS min_cutoff_score_current,
  NULL::numeric   AS min_cutoff_score_prev,
  NULL::numeric   AS max_cutoff_score_current,
  NULL::numeric   AS max_cutoff_score_prev,
  NULL::text      AS qt_vagas_ofertadas_current,
  NULL::text      AS qt_vagas_ofertadas_prev,
  NULL::text      AS qt_inscricao_current,
  NULL::text      AS qt_inscricao_prev,
  NULL::boolean   AS vagas_ociosas_current,
  NULL::boolean   AS vagas_ociosas_prev
FROM public.partner_opportunities po
  JOIN public.institutions i        ON i.id = po.institution_id
  LEFT JOIN public.partner_institutions pi ON pi.institution_id = i.id
  LEFT JOIN public.institutions_info_emec ie  ON ie.institution_id = i.id
  LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
WHERE (po.status)::text = ANY (ARRAY['incoming','opened','closed']);

CREATE UNIQUE INDEX IF NOT EXISTS idx_v_unified_opportunities_id         ON public.v_unified_opportunities (unified_id);
CREATE INDEX        IF NOT EXISTS idx_v_unified_opportunities_institution ON public.v_unified_opportunities (institution_id);
CREATE INDEX        IF NOT EXISTS idx_v_unified_opportunities_type        ON public.v_unified_opportunities (type);

GRANT SELECT ON public.v_unified_opportunities TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.v_unified_institutions AS
WITH inst_opps AS (
  SELECT v.institution_id, array_agg(DISTINCT v.opportunity_type) AS opp_types
  FROM public.v_unified_opportunities v GROUP BY v.institution_id
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
  io.opp_types,
  COALESCE(sisu.academic_organization,  ie.academic_organization)  AS academic_organization,
  COALESCE(sisu.administrative_category, ie.administrative_category) AS administrative_category
FROM public.institutions i
  LEFT JOIN public.partner_institutions pi  ON pi.institution_id = i.id
  LEFT JOIN public.institutions_info_emec ie   ON ie.institution_id = i.id
  LEFT JOIN public.institutions_info_sisu sisu ON sisu.institution_id = i.id
  LEFT JOIN inst_opps io ON io.institution_id = i.id;

GRANT SELECT ON public.v_unified_institutions TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_unified_opportunities_by_distance(
  p_lat  DOUBLE PRECISION,
  p_long DOUBLE PRECISION
)
RETURNS TABLE (
  unified_id               TEXT,
  title                    TEXT,
  provider_name            TEXT,
  type                     TEXT,
  opportunity_type         TEXT,
  category                 TEXT,
  is_partner               BOOLEAN,
  location                 TEXT,
  badges                   JSONB,
  created_at               TIMESTAMPTZ,
  external_redirect_url    TEXT,
  external_redirect_enabled BOOLEAN,
  status                   TEXT,
  starts_at                TIMESTAMPTZ,
  ends_at                  TIMESTAMPTZ,
  match_score              NUMERIC,
  institution_cover_url    TEXT,
  nu_vagas_autorizadas     TEXT,
  institution_id           UUID,
  institution_igc          TEXT,
  institution_organization TEXT,
  institution_category     TEXT,
  institution_site         TEXT,
  eligibility_criteria     JSONB,
  benefits                 JSONB,
  brand_color              TEXT,
  weights                  JSONB,
  institution_acronym      TEXT,
  latitude                 DOUBLE PRECISION,
  longitude                DOUBLE PRECISION,
  min_cutoff_score_current NUMERIC,
  min_cutoff_score_prev    NUMERIC,
  max_cutoff_score_current NUMERIC,
  max_cutoff_score_prev    NUMERIC,
  qt_vagas_ofertadas_current TEXT,
  qt_vagas_ofertadas_prev    TEXT,
  qt_inscricao_current       TEXT,
  qt_inscricao_prev          TEXT,
  vagas_ociosas_current      BOOLEAN,
  vagas_ociosas_prev         BOOLEAN,
  distance_km              NUMERIC
)
LANGUAGE sql STABLE
AS $func$
  SELECT
    v.unified_id, v.title, v.provider_name, v.type, v.opportunity_type,
    v.category, v.is_partner, v.location, v.badges, v.created_at,
    v.external_redirect_url, v.external_redirect_enabled, v.status,
    v.starts_at, v.ends_at, v.match_score, v.institution_cover_url,
    v.nu_vagas_autorizadas, v.institution_id, v.institution_igc,
    v.institution_organization, v.institution_category, v.institution_site,
    v.eligibility_criteria, v.benefits, v.brand_color, v.weights,
    v.institution_acronym, v.latitude, v.longitude,
    v.min_cutoff_score_current, v.min_cutoff_score_prev,
    v.max_cutoff_score_current, v.max_cutoff_score_prev,
    v.qt_vagas_ofertadas_current, v.qt_vagas_ofertadas_prev,
    v.qt_inscricao_current, v.qt_inscricao_prev,
    v.vagas_ociosas_current, v.vagas_ociosas_prev,
    (6371 * acos(
      cos(radians(p_lat)) * cos(radians(v.latitude)) *
      cos(radians(v.longitude) - radians(p_long)) +
      sin(radians(p_lat)) * sin(radians(v.latitude))
    ))::NUMERIC AS distance_km
  FROM public.v_unified_opportunities v
  WHERE v.latitude IS NOT NULL AND v.longitude IS NOT NULL
  ORDER BY distance_km ASC;
$func$;

-- ====================================================================================
-- ProUni Vacancies ETL (Independent: Creates Inst, Campus, Courses, Opp skeletons)
-- ====================================================================================

CREATE OR REPLACE FUNCTION public.etl_import_prouni_vacancies(
  p_program_id uuid,
  p_limit integer DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_log_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '10min'
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_inst_id           UUID;
  v_campus_id         UUID;
  v_course_id         UUID;
  v_opp_id            UUID;
  v_raw_count         INTEGER;
  v_skipped           INTEGER;
  v_vacancies_in_db   INTEGER;
  v_ampla_total       BIGINT;
  v_cota_total        BIGINT;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;
  SELECT COUNT(*) INTO v_raw_count FROM public.rawprounivacancies;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed) VALUES (p_program_id, 'prouni_vacancies', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE v_log_id := p_log_id; END IF;

  -- 1. Institutions
  FOR v_rec IN SELECT DISTINCT "CO_IES"::text AS external_code, "NO_IES" AS name FROM public.rawprounivacancies WHERE "CO_IES" IS NOT NULL LOOP
    BEGIN
      INSERT INTO public.institutions (external_code, name) VALUES (v_rec.external_code, v_rec.name) ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'IES: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- 2. Campus
  FOR v_rec IN SELECT DISTINCT "CO_IES"::text AS inst_ext, "CO_CAMPUS"::text AS external_code, "NO_CAMPUS" AS name FROM public.rawprounivacancies WHERE "CO_IES" IS NOT NULL AND "CO_CAMPUS" IS NOT NULL LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_ext;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.campus (institution_id, external_code, name) VALUES (v_inst_id, v_rec.external_code, v_rec.name) ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Campus: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- 3. Courses
  FOR v_rec IN SELECT DISTINCT "CO_CAMPUS"::text AS campus_ext, "CO_CURSO"::text AS course_code, "NO_CURSO" AS course_name FROM public.rawprounivacancies WHERE "CO_CAMPUS" IS NOT NULL AND "CO_CURSO" IS NOT NULL LOOP
    BEGIN
      SELECT id INTO v_campus_id FROM public.campus WHERE external_code = v_rec.campus_ext;
      IF v_campus_id IS NOT NULL THEN
        INSERT INTO public.courses (campus_id, course_code, course_name) VALUES (v_campus_id, v_rec.course_code, v_rec.course_name) ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Course: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- 4. Opportunities and Vacancies
  FOR v_rec IN
    SELECT v."CO_CURSO"::text AS co_curso, v."CO_CAMPUS"::text AS co_campus, v."DS_TIPO_BOLSA", COALESCE(v."BOLSAS_AMPLA_OFERTADA"::integer, 0) AS bolsas_ampla_ofertada, COALESCE(v."BOLSAS_COTA_OFERTADA"::integer, 0) AS bolsas_cota_ofertada
    FROM (SELECT * FROM public.rawprounivacancies ORDER BY "CO_CURSO", "CO_CAMPUS", "DS_TIPO_BOLSA" LIMIT p_limit OFFSET p_offset) v
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id FROM public.courses c JOIN public.campus ca ON ca.id = c.campus_id WHERE c.course_code = v_rec.co_curso AND ca.external_code = v_rec.co_campus LIMIT 1;
      IF v_course_id IS NOT NULL THEN
        -- Create Opportunity Skeleton so that v_unified_opportunities works without Base
        INSERT INTO public.opportunities (course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data)
        VALUES (v_course_id, v_semester, 'Aguardando Consolidada', v_rec."DS_TIPO_BOLSA", v_year, 'prouni', NULL, '{}'::jsonb)
        ON CONFLICT (course_id, opportunity_type, year, semester, shift, scholarship_type) DO NOTHING;
        
        -- Insert into courses_prouni_vacancies
        INSERT INTO public.courses_prouni_vacancies (course_id, ds_tipo_bolsa, bolsas_ampla_ofertada, bolsas_cota_ofertada, year, semester)
        VALUES (v_course_id, v_rec."DS_TIPO_BOLSA", v_rec.bolsas_ampla_ofertada, v_rec.bolsas_cota_ofertada, v_year, v_semester)
        ON CONFLICT (course_id, ds_tipo_bolsa, year, semester) DO UPDATE SET bolsas_ampla_ofertada = EXCLUDED.bolsas_ampla_ofertada, bolsas_cota_ofertada = EXCLUDED.bolsas_cota_ofertada, updated_at = now();
        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    v_skipped := v_raw_count - v_total_processed_in_log;
    SELECT COUNT(*) INTO v_vacancies_in_db FROM public.courses_prouni_vacancies WHERE year = v_year AND semester = v_semester;
    SELECT COALESCE(SUM(bolsas_ampla_ofertada), 0) INTO v_ampla_total FROM public.courses_prouni_vacancies WHERE year = v_year AND semester = v_semester;
    SELECT COALESCE(SUM(bolsas_cota_ofertada), 0) INTO v_cota_total FROM public.courses_prouni_vacancies WHERE year = v_year AND semester = v_semester;

    IF v_errors IS NULL THEN
      v_detail_msg := 'Vagas ProUni importadas com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• Linhas mapeadas:                ' || v_total_processed_in_log || chr(10) || '• Linhas ignoradas (s/ curso):    ' || v_skipped || chr(10) || '• Registros em courses_prouni_vacancies: ' || v_vacancies_in_db || chr(10) || '• Total bolsas ampla concorrência: ' || v_ampla_total || chr(10) || '• Total bolsas cota:              ' || v_cota_total;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawprounivacancies;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;

-- Delete skeleton opportunities in etl_import_prouni (Base)
CREATE OR REPLACE FUNCTION public.etl_import_prouni(
  p_program_id uuid,
  p_limit integer DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_log_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '10min'
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_raw_count         INTEGER;
  v_inst_count        INTEGER;
  v_campus_count      INTEGER;
  v_course_count      INTEGER;
  v_opp_count         INTEGER;
  v_opp_integral      INTEGER;
  v_opp_parcial       INTEGER;
  v_opp_with_cutoff   INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawprouni;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed) VALUES (p_program_id, 'prouni_base', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE v_log_id := p_log_id; END IF;

  BEGIN
    -- 1. Institutions
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT "CODIGO_IES"::text, "IES"
    FROM (SELECT * FROM public.rawprouni ORDER BY "CODIGO_IES", "CODIGO_CAMPUS", "CODIGO_CURSO", "CO_TURNO" LIMIT p_limit OFFSET p_offset) r
    WHERE "CODIGO_IES" IS NOT NULL
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;

    -- 2. Campus
    INSERT INTO public.campus (institution_id, external_code, name, city, state)
    SELECT DISTINCT i.id AS institution_id, r."CODIGO_CAMPUS"::text AS external_code, r."CAMPUS" AS name, r."MUNICIPIO" AS city, r."UF" AS state
    FROM (SELECT * FROM public.rawprouni ORDER BY "CODIGO_IES", "CODIGO_CAMPUS", "CODIGO_CURSO", "CO_TURNO" LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = r."CODIGO_IES"::text
    WHERE r."CODIGO_CAMPUS" IS NOT NULL
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name, city = EXCLUDED.city, state = EXCLUDED.state;

    -- 3. Courses
    INSERT INTO public.courses (campus_id, course_code, course_name)
    SELECT DISTINCT ca.id AS campus_id, r."CODIGO_CURSO"::text AS course_code, r."CURSO" AS course_name
    FROM (SELECT * FROM public.rawprouni ORDER BY "CODIGO_IES", "CODIGO_CAMPUS", "CODIGO_CURSO", "CO_TURNO" LIMIT p_limit OFFSET p_offset) r
    JOIN public.campus ca ON ca.external_code = r."CODIGO_CAMPUS"::text
    WHERE r."CODIGO_CURSO" IS NOT NULL
    ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name;

    -- Delete Skeletons before inserting Base opportunities to avoid duplication
    DELETE FROM public.opportunities WHERE shift = 'Aguardando Consolidada' AND opportunity_type = 'prouni' AND year = v_year AND semester = v_semester;

    -- 4. Opportunities
    WITH batched_raw AS (
      SELECT * FROM public.rawprouni ORDER BY "CODIGO_IES", "CODIGO_CAMPUS", "CODIGO_CURSO", "CO_TURNO" LIMIT p_limit OFFSET p_offset
    ),
    mapped_raw AS (
      SELECT c.id AS course_id, r."SEMESTRE"::text AS semester, r."CO_TURNO" AS shift, r."TIPO_BOLSA" AS scholarship_type, v_year AS year, 'prouni' AS opportunity_type,
        CASE WHEN r."NOTA_DE_CORTE" IS NULL OR TRIM(r."NOTA_DE_CORTE") = '' THEN NULL ELSE REPLACE(REPLACE(TRIM(r."NOTA_DE_CORTE"), '.', ''), ',', '.')::numeric END AS cutoff_score,
        to_jsonb(r) AS raw_data
      FROM batched_raw r
      JOIN public.campus ca ON ca.external_code = r."CODIGO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CODIGO_CURSO"::text
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, opportunity_type, year, semester, shift, scholarship_type) * FROM mapped_raw ORDER BY course_id, opportunity_type, year, semester, shift, scholarship_type, cutoff_score DESC
    ),
    updated AS (
      UPDATE public.opportunities o SET cutoff_score = m.cutoff_score, raw_data = m.raw_data, updated_at = now()
      FROM mapped m WHERE o.course_id = m.course_id AND o.opportunity_type = m.opportunity_type AND o.year = m.year AND o.semester = m.semester AND o.shift = m.shift AND o.scholarship_type = m.scholarship_type
      RETURNING o.id
    ),
    inserted AS (
      INSERT INTO public.opportunities (course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data)
      SELECT m.course_id, m.semester, m.shift, m.scholarship_type, m.year, m.opportunity_type, m.cutoff_score, m.raw_data
      FROM mapped m WHERE NOT EXISTS (SELECT 1 FROM public.opportunities o WHERE o.course_id = m.course_id AND o.opportunity_type = m.opportunity_type AND o.year = m.year AND o.semester = m.semester AND o.shift = m.shift AND o.scholarship_type = m.scholarship_type)
      RETURNING id
    )
    SELECT (SELECT count(*) FROM mapped_raw) INTO v_processed;

  EXCEPTION WHEN OTHERS THEN v_errors := SQLERRM;
  END;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;
  IF v_processed = 0 THEN v_has_more := FALSE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    UPDATE public.opportunities SET scholarship_tags = '[["BOLSA_INTEGRAL"]]'::jsonb WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0) AND (UPPER(scholarship_type) LIKE '%INTEGRAL%' OR UPPER(scholarship_type) = 'BOLSA INTEGRAL');
    UPDATE public.opportunities SET scholarship_tags = '[["BOLSA_PARCIAL"]]'::jsonb WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0) AND (UPPER(scholarship_type) LIKE '%PARCIAL%' OR UPPER(scholarship_type) LIKE '%50%' OR UPPER(scholarship_type) = 'BOLSA PARCIAL 50%');

    SELECT COUNT(DISTINCT "CODIGO_IES") INTO v_inst_count FROM public.rawprouni WHERE "CODIGO_IES" IS NOT NULL;
    SELECT COUNT(DISTINCT "CODIGO_CAMPUS") INTO v_campus_count FROM public.rawprouni WHERE "CODIGO_CAMPUS" IS NOT NULL;
    SELECT COUNT(DISTINCT "CODIGO_CURSO") INTO v_course_count FROM public.rawprouni WHERE "CODIGO_CURSO" IS NOT NULL;
    SELECT COUNT(*) INTO v_opp_count FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';
    SELECT COUNT(*) INTO v_opp_integral FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND scholarship_tags::text LIKE '%BOLSA_INTEGRAL%';
    SELECT COUNT(*) INTO v_opp_parcial FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND scholarship_tags::text LIKE '%BOLSA_PARCIAL%';
    SELECT COUNT(*) INTO v_opp_with_cutoff FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND cutoff_score IS NOT NULL;

    IF v_errors IS NULL THEN
      v_detail_msg := 'Base ProUni importada com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• IES distintas no arquivo:       ' || v_inst_count || chr(10) || '• Campus distintos:               ' || v_campus_count || chr(10) || '• Cursos distintos:               ' || v_course_count || chr(10) || '• Oportunidades no ciclo:         ' || v_opp_count || chr(10) || '• Bolsas integrais:               ' || v_opp_integral || chr(10) || '• Bolsas parciais:                ' || v_opp_parcial || chr(10) || '• Opps. com nota de corte:        ' || v_opp_with_cutoff;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawprouni;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;
