-- Fix historical data propagation for Sisu+ (2026.2) and others
-- Resolves the hardcoded 'year - 1' logic to use 'prev_program_id' when available.

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
    -- qt_inscricao: from sisu_vacancies (populated by etl_import_sisu)
    sv_curr.qt_inscricao AS qt_inscricao_current,
    sv_prev_inscricao.qt_inscricao AS qt_inscricao_prev,
    -- vagas_ociosas_current: BOOLEAN — any modality in current cycle where vagas > inscricao
    vc_curr.has_vagas_ociosas AS vagas_ociosas_current,
    -- vagas_ociosas_prev: BOOLEAN — any modality in prev cycle where vagas > inscricao (Opção A)
    vc_prev.has_vagas_ociosas AS vagas_ociosas_prev

  FROM public.opportunities o
    JOIN public.programs p
        ON p.type = 'sisu'::text AND p.status <> 'inactive'::text
    LEFT JOIN public.programs p_prev ON p_prev.id = p.prev_program_id
    JOIN public.courses c         ON c.id = o.course_id
    JOIN public.campus cp         ON cp.id = c.campus_id
    JOIN public.institutions i    ON i.id = cp.institution_id

    -- Cutoff scores current
    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'sisu' AND opp.course_id = o.course_id AND opp.year = p.cycle_year
    ) s_curr ON true

    -- Cutoff scores prev
    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      JOIN public.courses cp_prev ON cp_prev.id = opp.course_id
      WHERE opp.opportunity_type = 'sisu' AND cp_prev.campus_id = c.campus_id AND cp_prev.course_name = c.course_name AND opp.year = COALESCE(p_prev.cycle_year, p.cycle_year - 1) AND (p_prev.id IS NULL OR opp.semester = p_prev.cycle_semester)
    ) s_prev ON true

    -- Important dates
    LEFT JOIN LATERAL (
      SELECT d.start_date, d.end_date
      FROM public.important_dates d
      WHERE d.type = 'sisu' AND d.controls_opportunity_dates = true
      ORDER BY d.start_date DESC LIMIT 1
    ) id_dates ON true

    -- Sisu vacancies current (for weights, nu_vagas_autorizadas, qt_vagas_ofertadas, qt_inscricao)
    LEFT JOIN LATERAL (
      SELECT sv.*
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.year = p.cycle_year AND op.opportunity_type = 'sisu'
      LIMIT 1
    ) sv_curr ON true

    -- Sisu vacancies prev (for qt_vagas_ofertadas_prev)
    LEFT JOIN LATERAL (
      SELECT sv.qt_vagas_ofertadas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      JOIN public.courses cp_prev ON cp_prev.id = op.course_id
      WHERE cp_prev.campus_id = c.campus_id AND cp_prev.course_name = c.course_name AND op.year = COALESCE(p_prev.cycle_year, p.cycle_year - 1) AND (p_prev.id IS NULL OR op.semester = p_prev.cycle_semester) AND op.opportunity_type = 'sisu'
      LIMIT 1
    ) sv_prev ON true

    -- qt_inscricao_prev: pick one modality from prev cycle (they're per-modality; representative)
    LEFT JOIN LATERAL (
      SELECT sv.qt_inscricao
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      JOIN public.courses cp_prev ON cp_prev.id = op.course_id
      WHERE cp_prev.campus_id = c.campus_id AND cp_prev.course_name = c.course_name AND op.year = COALESCE(p_prev.cycle_year, p.cycle_year - 1) AND (p_prev.id IS NULL OR op.semester = p_prev.cycle_semester) AND op.opportunity_type = 'sisu'
        AND sv.qt_inscricao IS NOT NULL
      ORDER BY sv.qt_inscricao::integer DESC
      LIMIT 1
    ) sv_prev_inscricao ON true

    -- vagas_ociosas_current BOOLEAN
    LEFT JOIN LATERAL (
      SELECT 
        CASE 
          WHEN COUNT(sv.qt_inscricao) = 0 THEN NULL
          ELSE bool_or(replace(sv.qt_vagas_ofertadas, '.', '')::integer > sv.qt_inscricao::integer)
        END AS has_vagas_ociosas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id
        AND op.opportunity_type = 'sisu'
        AND op.year = p.cycle_year
        AND sv.qt_inscricao IS NOT NULL
        AND sv.qt_vagas_ofertadas IS NOT NULL
    ) vc_curr ON true

    -- vagas_ociosas_prev BOOLEAN (Opção A: prev cycle data only)
    LEFT JOIN LATERAL (
      SELECT 
        CASE 
          WHEN COUNT(sv.qt_inscricao) = 0 THEN NULL
          ELSE bool_or(replace(sv.qt_vagas_ofertadas, '.', '')::integer > sv.qt_inscricao::integer)
        END AS has_vagas_ociosas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      JOIN public.courses cp_prev ON cp_prev.id = op.course_id
      WHERE cp_prev.campus_id = c.campus_id AND cp_prev.course_name = c.course_name
        AND op.opportunity_type = 'sisu'
        AND op.year = COALESCE(p_prev.cycle_year, p.cycle_year - 1) AND (p_prev.id IS NULL OR op.semester = p_prev.cycle_semester)
        AND sv.qt_inscricao IS NOT NULL
        AND sv.qt_vagas_ofertadas IS NOT NULL
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
    -- vagas_ociosas_current BOOLEAN: any scholarship type with unfilled spots in current cycle
    (COALESCE(pv_curr.vagas_ociosas, 0) > 0)::boolean AS vagas_ociosas_current,
    -- vagas_ociosas_prev BOOLEAN: any scholarship type with unfilled spots in prev cycle
    (COALESCE(pv_prev.vagas_ociosas, 0) > 0)::boolean AS vagas_ociosas_prev

  FROM public.opportunities o
    JOIN public.programs p ON p.type = 'prouni' AND p.status <> 'inactive'
    LEFT JOIN public.programs p_prev ON p_prev.id = p.prev_program_id
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
      WHERE opp.opportunity_type = 'prouni' AND opp.course_id = o.course_id AND opp.year = COALESCE(p_prev.cycle_year, p.cycle_year - 1) AND (p_prev.id IS NULL OR opp.semester = p_prev.cycle_semester)
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
      WHERE pv.course_id = o.course_id AND pv.year = COALESCE(p_prev.cycle_year, p.cycle_year - 1)
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
WHERE (po.status)::text = ANY (ARRAY['incoming','opened','closed']);;

CREATE UNIQUE INDEX IF NOT EXISTS idx_v_unified_opportunities_id         ON public.v_unified_opportunities (unified_id);
CREATE INDEX        IF NOT EXISTS idx_v_unified_opportunities_institution ON public.v_unified_opportunities (institution_id);
CREATE INDEX        IF NOT EXISTS idx_v_unified_opportunities_type        ON public.v_unified_opportunities (type);

GRANT SELECT ON public.v_unified_opportunities TO anon, authenticated, service_role;

-- Recreate function
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

CREATE OR REPLACE FUNCTION public.etl_import_sisu_vacancies(p_program_id uuid, p_limit integer DEFAULT NULL::integer, p_offset integer DEFAULT 0, p_log_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_prev_year         INTEGER;
  v_prev_semester     TEXT;
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
  v_opps_with_vaga    INTEGER;
  v_opps_without_vaga INTEGER;
  v_opps_total        INTEGER;
  v_historical_prop   INTEGER;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
  v_batch_rows        INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  SELECT p_prev.cycle_year, p_prev.cycle_semester INTO v_prev_year, v_prev_semester
  FROM public.programs p_prev
  WHERE p_prev.id = (SELECT prev_program_id FROM public.programs WHERE id = p_program_id);

  IF v_prev_year IS NULL THEN
    v_prev_year := v_year - 1;
    v_prev_semester := v_semester;
  END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisuvacancies;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'sisu_vacancies', 'running', now(), 0)
    RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  -- Institutions
  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS external_code, "NO_IES" AS name
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      INSERT INTO public.institutions (external_code, name)
      VALUES (v_rec.external_code, v_rec.name)
      ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'IES: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Institutions SISU info
  FOR v_rec IN
    SELECT DISTINCT ON ("CO_IES")
      "CO_IES"::text AS inst_external_code,
      "SG_IES" AS acronym,
      "DS_ORGANIZACAO_ACADEMICA" AS academic_organization,
      "DS_CATEGORIA_ADM" AS administrative_category
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_sisu (institution_id, acronym, academic_organization, administrative_category)
        VALUES (v_inst_id, v_rec.acronym, v_rec.academic_organization, v_rec.administrative_category)
        ON CONFLICT (institution_id) DO UPDATE SET
          acronym = EXCLUDED.acronym, academic_organization = EXCLUDED.academic_organization, administrative_category = EXCLUDED.administrative_category, updated_at = now();
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Info: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Campus
  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS name, "NO_MUNICIPIO_CAMPUS" AS municipio, "SG_UF_CAMPUS" AS state, "DS_REGIAO" AS region
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.campus (institution_id, name, city, state, region)
        VALUES (
          v_inst_id, v_rec.name,
          COALESCE((SELECT c.name FROM public.cities c WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(v_rec.municipio)) AND c.state = v_rec.state LIMIT 1), v_rec.municipio),
          v_rec.state, v_rec.region
        ) ON CONFLICT (institution_id, name, city) DO UPDATE SET state = EXCLUDED.state, region = EXCLUDED.region;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Campus: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Courses
  FOR v_rec IN
    SELECT DISTINCT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS campus_name, "CO_IES_CURSO"::text AS course_code, "NO_CURSO" AS course_name, "DS_GRAU" AS degree_type
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT ca.id INTO v_campus_id FROM public.campus ca JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code AND ca.name = v_rec.campus_name LIMIT 1;

      IF v_campus_id IS NOT NULL THEN
        INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
        VALUES (v_campus_id, v_rec.course_code, v_rec.course_name, v_rec.degree_type)
        ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name, degree_type = EXCLUDED.degree_type;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Course: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Opportunities and vacancies
  FOR v_rec IN
    SELECT "CO_IES"::text AS inst_external_code, "NO_CAMPUS" AS campus_name, "CO_IES_CURSO"::text AS course_code, "DS_TURNO" AS shift, "DS_MOD_CONCORRENCIA" AS concurrency_type, *
    FROM (
      SELECT * FROM public.rawsisuvacancies
      ORDER BY "EDICAO", "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA"
      LIMIT p_limit OFFSET p_offset
    ) batch
    WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL AND "CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id FROM public.courses c JOIN public.campus ca ON ca.id = c.campus_id JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code AND ca.name = v_rec.campus_name AND c.course_code = v_rec.course_code LIMIT 1;

      IF v_course_id IS NOT NULL THEN
        INSERT INTO public.opportunities (course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data)
        VALUES (v_course_id, v_semester, v_rec.shift, v_rec.concurrency_type, (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = v_rec.concurrency_type LIMIT 1), v_year, 'sisu', NULL, '{}'::jsonb)
        ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type) WHERE concurrency_type IS NOT NULL
        DO UPDATE SET concurrency_tags = EXCLUDED.concurrency_tags, updated_at = now() RETURNING id INTO v_opp_id;

        IF v_opp_id IS NOT NULL THEN
          INSERT INTO public.opportunities_sisu_vacancies (opportunity_id, qt_semestre, nu_vagas_autorizadas, qt_vagas_ofertadas, nu_percentual_bonus, tp_mod_concorrencia, tp_cota, ds_mod_concorrencia, peso_redacao, nota_minima_redacao, peso_linguagens, nota_minima_linguagens, peso_matematica, nota_minima_matematica, peso_ciencias_humanas, nota_minima_ciencias_humanas, peso_ciencias_natureza, nota_minima_ciencias_natureza, nu_media_minima_enem, perc_uf_ibge_ppi, perc_uf_ibge_pp, perc_uf_ibge_i, perc_uf_ibge_q, perc_uf_ibge_pcd, nu_perc_lei, nu_perc_ppi, nu_perc_pp, nu_perc_i, nu_perc_q, nu_perc_pcd)
          VALUES (v_opp_id, v_rec."QT_SEMESTRE", v_rec."NU_VAGAS_AUTORIZADAS", v_rec."QT_VAGAS_OFERTADAS", v_rec."NU_PERCENTUAL_BONUS", v_rec."TP_MOD_CONCORRENCIA", v_rec."TP_COTA", v_rec."DS_MOD_CONCORRENCIA", COALESCE(NULLIF(REPLACE(v_rec."PESO_REDACAO", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_REDACAO", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_LINGUAGENS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_LINGUAGENS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_MATEMATICA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_MATEMATICA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_HUMANAS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_HUMANAS", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_NATUREZA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_NATUREZA", ',', '.'), ''), '0')::numeric, COALESCE(NULLIF(REPLACE(v_rec."NU_MEDIA_MINIMA_ENEM", ',', '.'), ''), '0')::numeric, v_rec."PERC_UF_IBGE_PPI", v_rec."PERC_UF_IBGE_PP", v_rec."PERC_UF_IBGE_I", v_rec."PERC_UF_IBGE_Q", v_rec."PERC_UF_IBGE_PCD", v_rec."NU_PERC_LEI", v_rec."NU_PERC_PPI", v_rec."NU_PERC_PP", v_rec."NU_PERC_I", v_rec."NU_PERC_Q", v_rec."NU_PERC_PCD")
          ON CONFLICT (opportunity_id) DO UPDATE SET qt_semestre = EXCLUDED.qt_semestre, nu_vagas_autorizadas = EXCLUDED.nu_vagas_autorizadas, qt_vagas_ofertadas = EXCLUDED.qt_vagas_ofertadas, nu_percentual_bonus = EXCLUDED.nu_percentual_bonus, tp_mod_concorrencia = EXCLUDED.tp_mod_concorrencia, tp_cota = EXCLUDED.tp_cota, ds_mod_concorrencia = EXCLUDED.ds_mod_concorrencia, peso_redacao = EXCLUDED.peso_redacao, nota_minima_redacao = EXCLUDED.nota_minima_redacao, peso_linguagens = EXCLUDED.peso_linguagens, nota_minima_linguagens = EXCLUDED.nota_minima_linguagens, peso_matematica = EXCLUDED.peso_matematica, nota_minima_matematica = EXCLUDED.nota_minima_matematica, peso_ciencias_humanas = EXCLUDED.peso_ciencias_humanas, nota_minima_ciencias_humanas = EXCLUDED.nota_minima_ciencias_humanas, peso_ciencias_natureza = EXCLUDED.peso_ciencias_natureza, nota_minima_ciencias_natureza = EXCLUDED.nota_minima_ciencias_natureza, nu_media_minima_enem = EXCLUDED.nu_media_minima_enem, updated_at = now();

          v_processed := v_processed + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Opp/Vaga: ' || SQLERRM, 1500);
    END;
  END LOOP;

  IF p_limit IS NOT NULL THEN
    SELECT COUNT(*) INTO v_batch_rows FROM (
      SELECT 1 FROM public.rawsisuvacancies LIMIT p_limit OFFSET p_offset
    ) sub;
    v_has_more := (v_batch_rows = p_limit);
  ELSE
    v_has_more := FALSE;
  END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    BEGIN
      -- Propagate cutoff_score from previous cycle (handling MEC data inconsistencies)
      UPDATE public.opportunities op_curr 
      SET cutoff_score = op_prev.cutoff_score 
      FROM public.opportunities op_prev
      JOIN public.courses c_prev ON c_prev.id = op_prev.course_id
      JOIN public.courses c_curr ON c_curr.campus_id = c_prev.campus_id AND c_curr.course_name = c_prev.course_name
      WHERE op_curr.course_id = c_curr.id 
      AND op_curr.opportunity_type = 'sisu' AND op_curr.year = v_year AND op_curr.semester = v_semester 
      AND op_prev.opportunity_type = 'sisu' AND op_prev.year = v_prev_year AND op_prev.semester = v_prev_semester 
      AND op_curr.shift = op_prev.shift 
      AND (
          op_curr.concurrency_type = op_prev.concurrency_type OR
          (op_curr.concurrency_tags IS NOT NULL AND op_prev.concurrency_tags IS NOT NULL AND 
           op_curr.concurrency_tags::text = op_prev.concurrency_tags::text)
      )
      AND op_prev.cutoff_score IS NOT NULL AND op_curr.cutoff_score IS NULL;

      -- qt_vagas_ofertadas_prev propagation (handling MEC data inconsistencies)
      UPDATE public.opportunities_sisu_vacancies osv_curr
      SET qt_vagas_ofertadas_prev = osv_prev.qt_vagas_ofertadas
      FROM public.opportunities o_curr
      JOIN public.courses c_curr ON c_curr.id = o_curr.course_id
      JOIN public.courses c_prev ON c_prev.campus_id = c_curr.campus_id AND c_prev.course_name = c_curr.course_name
      JOIN public.opportunities o_prev ON o_prev.course_id = c_prev.id AND o_prev.shift = o_curr.shift AND (o_curr.concurrency_type = o_prev.concurrency_type OR (o_curr.concurrency_tags IS NOT NULL AND o_prev.concurrency_tags IS NOT NULL AND o_curr.concurrency_tags::text = o_prev.concurrency_tags::text)) AND o_prev.year = v_prev_year AND o_prev.semester = v_prev_semester AND o_prev.opportunity_type = 'sisu'
      JOIN public.opportunities_sisu_vacancies osv_prev ON osv_prev.opportunity_id = o_prev.id
      WHERE osv_curr.opportunity_id = o_curr.id AND o_curr.year = v_year AND o_curr.semester = v_semester AND o_curr.opportunity_type = 'sisu';

      GET DIAGNOSTICS v_historical_prop = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_historical_prop := 0; v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Propagation: ' || SQLERRM, 1500);
    END;

    v_skipped := v_raw_count - v_total_processed_in_log;
    SELECT COUNT(*) INTO v_vacancies_in_db FROM public.opportunities_sisu_vacancies osv JOIN public.opportunities o ON o.id = osv.opportunity_id WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';
    SELECT COUNT(*) INTO v_opps_total FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';
    SELECT COUNT(DISTINCT o.id) INTO v_opps_with_vaga FROM public.opportunities o JOIN public.opportunities_sisu_vacancies osv ON osv.opportunity_id = o.id WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';
    v_opps_without_vaga := v_opps_total - v_opps_with_vaga;

    IF v_errors IS NULL THEN
      v_detail_msg := 'Vagas SiSU importadas com sucesso.' || chr(10)
        || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10)
        || '• Vagas vinculadas (mapeadas):    ' || v_total_processed_in_log || chr(10)
        || '• Linhas ignoradas (s/ opp.):     ' || v_skipped || chr(10)
        || '• Registros em sisu_vacancies:    ' || v_vacancies_in_db || chr(10)
        || '• Oportunidades c/ vaga:          ' || v_opps_with_vaga || ' / ' || v_opps_total || chr(10)
        || '• Oportunidades s/ vaga:          ' || v_opps_without_vaga || chr(10)
        || '• Vagas c/ histórico propagado:   ' || COALESCE(v_historical_prop, 0);
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawsisuvacancies;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('vacancies_processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = LEFT(SQLERRM, 1500), finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$function$;

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
