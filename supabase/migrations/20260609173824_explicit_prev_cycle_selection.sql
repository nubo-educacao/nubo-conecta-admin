-- 20260609173824_explicit_prev_cycle_selection.sql

-- 1. Alter table programs
ALTER TABLE public.programs 
ADD COLUMN prev_program_id UUID REFERENCES public.programs(id) ON DELETE SET NULL,
ADD COLUMN is_fully_imported BOOLEAN DEFAULT false;

-- 2. Update the v_unified_opportunities to use prev_program_id instead of dynamic lateral join
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

    -- FIND PREV PROGRAM EXPLICITLY
    LEFT JOIN public.programs prev_program ON prev_program.id = p.prev_program_id

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

    -- FIND PREV PROGRAM EXPLICITLY
    LEFT JOIN public.programs prev_program ON prev_program.id = p.prev_program_id

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

-- 3. Modify SISU and ProUni ETL functions to mark program as fully imported
-- For SiSU, the base import is the final piece of data (since Vagas runs first).
CREATE OR REPLACE FUNCTION public.etl_import_sisu(
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
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisu;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'sisu', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  BEGIN
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT "SG_IES", "NO_IES" FROM (SELECT * FROM public.rawsisu ORDER BY "SG_IES", "NO_CAMPUS", "NO_CURSO", "DS_TURNO", "DS_GRAU" LIMIT p_limit OFFSET p_offset) r
    WHERE "SG_IES" IS NOT NULL
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;

    INSERT INTO public.campus (institution_id, external_code, name, city, state)
    SELECT DISTINCT i.id, r."NO_CAMPUS", r."NO_CAMPUS", r."NO_MUNICIPIO_CAMPUS", r."SG_UF_CAMPUS"
    FROM (SELECT * FROM public.rawsisu ORDER BY "SG_IES", "NO_CAMPUS", "NO_CURSO", "DS_TURNO", "DS_GRAU" LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = r."SG_IES"
    WHERE r."NO_CAMPUS" IS NOT NULL
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name, city = EXCLUDED.city, state = EXCLUDED.state;

    INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
    SELECT DISTINCT ca.id, r."NO_CURSO", r."NO_CURSO", r."DS_GRAU"
    FROM (SELECT * FROM public.rawsisu ORDER BY "SG_IES", "NO_CAMPUS", "NO_CURSO", "DS_TURNO", "DS_GRAU" LIMIT p_limit OFFSET p_offset) r
    JOIN public.campus ca ON ca.external_code = r."NO_CAMPUS"
    WHERE r."NO_CURSO" IS NOT NULL
    ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name, degree_type = EXCLUDED.degree_type;

    WITH batched_raw AS (SELECT * FROM public.rawsisu ORDER BY "SG_IES", "NO_CAMPUS", "NO_CURSO", "DS_TURNO", "DS_GRAU" LIMIT p_limit OFFSET p_offset),
    mapped_raw AS (
      SELECT c.id AS course_id, v_semester AS semester, r."DS_TURNO" AS shift, 'Ampla concorrência' AS scholarship_type, v_year AS year, 'sisu' AS opportunity_type,
        CASE WHEN r."NU_NOTACORTE" IS NULL OR r."NU_NOTACORTE" = '' THEN NULL ELSE r."NU_NOTACORTE"::numeric END AS cutoff_score,
        to_jsonb(r) AS raw_data
      FROM batched_raw r
      JOIN public.campus ca ON ca.external_code = r."NO_CAMPUS"
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."NO_CURSO"
    ),
    mapped AS (SELECT DISTINCT ON (course_id, opportunity_type, year, semester, shift, scholarship_type) * FROM mapped_raw ORDER BY course_id, opportunity_type, year, semester, shift, scholarship_type, cutoff_score DESC),
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
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;
  IF v_processed = 0 THEN v_has_more := FALSE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    SELECT COUNT(DISTINCT "SG_IES") INTO v_inst_count FROM public.rawsisu WHERE "SG_IES" IS NOT NULL;
    SELECT COUNT(DISTINCT "NO_CAMPUS") INTO v_campus_count FROM public.rawsisu WHERE "NO_CAMPUS" IS NOT NULL;
    SELECT COUNT(DISTINCT "NO_CURSO") INTO v_course_count FROM public.rawsisu WHERE "NO_CURSO" IS NOT NULL;
    SELECT COUNT(*) INTO v_opp_count FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

    IF v_errors IS NULL THEN
      v_detail_msg := 'Sisu importado com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• IES distintas no arquivo:       ' || v_inst_count || chr(10) || '• Campus distintos:               ' || v_campus_count || chr(10) || '• Cursos distintos:               ' || v_course_count || chr(10) || '• Oportunidades no ciclo:         ' || v_opp_count;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawsisu;
      
      -- Mark program as fully imported
      UPDATE public.programs SET is_fully_imported = true WHERE id = p_program_id;
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


-- For ProUni, the final step is Ocupadas.
CREATE OR REPLACE FUNCTION public.etl_import_prouni_occupied(
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
  v_course_id         UUID;
  v_raw_count         INTEGER;
  v_skipped           INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;
  SELECT COUNT(*) INTO v_raw_count FROM public.rawprouniocuppied;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed) VALUES (p_program_id, 'prouni_occupied', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE v_log_id := p_log_id; END IF;

  FOR v_rec IN
    SELECT v."CO_CURSO"::text AS co_curso, v."CO_CAMPUS"::text AS co_campus, v."DS_TIPO_BOLSA",
           COALESCE(v."BOLSAS_AMPLA_OCUPADA"::integer, 0) AS bolsas_ampla_ocupada, COALESCE(v."BOLSAS_COTA_OCUPADA"::integer, 0) AS bolsas_cota_ocupada
    FROM (SELECT * FROM public.rawprouniocuppied ORDER BY "CO_CURSO", "CO_CAMPUS", "DS_TIPO_BOLSA" LIMIT p_limit OFFSET p_offset) v
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id FROM public.courses c JOIN public.campus ca ON ca.id = c.campus_id WHERE c.course_code = v_rec.co_curso AND ca.external_code = v_rec.co_campus LIMIT 1;
      IF v_course_id IS NOT NULL THEN
        UPDATE public.courses_prouni_vacancies
        SET bolsas_ampla_ocupada = v_rec.bolsas_ampla_ocupada, bolsas_cota_ocupada = v_rec.bolsas_cota_ocupada, updated_at = now()
        WHERE course_id = v_course_id AND ds_tipo_bolsa = v_rec."DS_TIPO_BOLSA" AND year = v_year AND semester = v_semester;
        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    v_skipped := v_raw_count - v_total_processed_in_log;
    IF v_errors IS NULL THEN
      v_detail_msg := 'Ocupação ProUni importada com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• Linhas mapeadas:                ' || v_total_processed_in_log || chr(10) || '• Linhas ignoradas (s/ curso):    ' || v_skipped;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawprouniocuppied;
      
      -- Mark program as fully imported
      UPDATE public.programs SET is_fully_imported = true WHERE id = p_program_id;
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
