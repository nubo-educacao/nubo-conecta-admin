-- Migration: Year-Agnostic ETL Pipeline and Database Foundation
-- 20260603151700_year_agnostic_etl_foundation.sql

-- 1. Drop existing view dependencies CASCADE to allow column renames
DROP MATERIALIZED VIEW IF EXISTS public.mv_course_catalog CASCADE;
DROP VIEW IF EXISTS public.v_unified_institutions CASCADE;
DROP FUNCTION IF EXISTS public.get_unified_opportunities_by_distance(double precision, double precision) CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.v_unified_opportunities CASCADE;

-- 2. Rename historical columns to use generic _prev suffix
ALTER TABLE public.opportunities_sisu_vacancies RENAME COLUMN qt_inscricao_2025 TO qt_inscricao_prev;
ALTER TABLE public.opportunities_sisu_vacancies RENAME COLUMN vagas_ociosas_2025 TO vagas_ociosas_prev;
ALTER TABLE public.opportunities_sisu_vacancies RENAME COLUMN qt_vagas_ofertadas_2025 TO qt_vagas_ofertadas_prev;

ALTER TABLE public.courses RENAME COLUMN vagas_ociosas_2025 TO vagas_ociosas_prev;

-- 3. Add degree_type column to courses
ALTER TABLE public.courses ADD COLUMN IF NOT EXISTS degree_type text;

-- 4. Create etl_run_logs audit table
CREATE TABLE IF NOT EXISTS public.etl_run_logs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id      uuid REFERENCES public.programs(id),
  etl_type        text NOT NULL,
  status          text NOT NULL CHECK (status IN ('running', 'success', 'error')),
  records_processed integer,
  errors          text,
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz
);

-- 5. Drop legacy RPCs
DROP FUNCTION IF EXISTS public.etl_prouni_vacancies();
DROP FUNCTION IF EXISTS public.etl_sisu_approvals();
DROP FUNCTION IF EXISTS public.etl_sisu_approvals(integer);
DROP FUNCTION IF EXISTS public.etl_sisu_vacancies_2026();

-- 6. Create generic raw staging tables (without year suffixes) if not exist
CREATE TABLE IF NOT EXISTS public.rawprouni (LIKE public.rawprouni2025 INCLUDING ALL);
CREATE TABLE IF NOT EXISTS public.rawprounivacancies (LIKE public.rawprounivacancies2025 INCLUDING ALL);
CREATE TABLE IF NOT EXISTS public.rawprouniocuppied (LIKE public.rawprouniocuppied2025 INCLUDING ALL);
CREATE TABLE IF NOT EXISTS public.rawsisuvacancies (LIKE public.rawsisuvacancies2026 INCLUDING ALL);

-- Seed generic raw staging tables from 2025/2026 data
INSERT INTO public.rawprouni SELECT * FROM public.rawprouni2025 ON CONFLICT DO NOTHING;
INSERT INTO public.rawprounivacancies SELECT * FROM public.rawprounivacancies2025 ON CONFLICT DO NOTHING;
INSERT INTO public.rawprouniocuppied SELECT * FROM public.rawprouniocuppied2025 ON CONFLICT DO NOTHING;
INSERT INTO public.rawsisuvacancies SELECT * FROM public.rawsisuvacancies2026 ON CONFLICT DO NOTHING;

-- 7. Recreate View: v_unified_opportunities (year-agnostic, joins with programs)
CREATE MATERIALIZED VIEW public.v_unified_opportunities AS
SELECT sisu_branch.unified_id,
    sisu_branch.title,
    sisu_branch.provider_name,
    sisu_branch.type,
    sisu_branch.opportunity_type,
    sisu_branch.category,
    sisu_branch.is_partner,
    sisu_branch.location,
    sisu_branch.badges,
    sisu_branch.created_at,
    sisu_branch.external_redirect_url,
    sisu_branch.external_redirect_enabled,
    sisu_branch.status,
    sisu_branch.starts_at,
    sisu_branch.ends_at,
    sisu_branch.match_score,
    sisu_branch.min_cutoff_score,
    sisu_branch.max_cutoff_score,
    sisu_branch.institution_cover_url,
    sisu_branch.nu_vagas_autorizadas,
    sisu_branch.qt_vagas_ofertadas,
    sisu_branch.qt_inscricao_prev,
    sisu_branch.vagas_ociosas_prev,
    sisu_branch.institution_id,
    sisu_branch.institution_igc,
    sisu_branch.institution_organization,
    sisu_branch.institution_category,
    sisu_branch.institution_site,
    sisu_branch.eligibility_criteria,
    sisu_branch.benefits,
    sisu_branch.brand_color,
    sisu_branch.weights,
    sisu_branch.institution_acronym,
    sisu_branch.latitude,
    sisu_branch.longitude
   FROM ( SELECT DISTINCT ON (c.id) 'mec_'::text || c.id::text AS unified_id,
            c.course_name AS title,
            i.name AS provider_name,
            'sisu'::text AS type,
            'sisu'::text AS opportunity_type,
            'public_universities'::text AS category,
            false AS is_partner,
            (cp.city || ', '::text) || cp.state AS location,
            jsonb_build_array(o.shift) - 'null'::text AS badges,
            o.created_at,
            NULL::text AS external_redirect_url,
            false AS external_redirect_enabled,
            'approved'::text AS status,
            id_dates.start_date AS starts_at,
            id_dates.end_date AS ends_at,
            NULL::numeric AS match_score,
            s.min_cutoff AS min_cutoff_score,
            s.max_cutoff AS max_cutoff_score,
            NULL::text AS institution_cover_url,
            sv.nu_vagas_autorizadas,
            sv.qt_vagas_ofertadas,
            sv.qt_inscricao_prev,
            sv.vagas_ociosas_prev,
            i.id AS institution_id,
            ie.igc AS institution_igc,
            ie.academic_organization AS institution_organization,
            ie.administrative_category AS institution_category,
            ie.site AS institution_site,
            NULL::jsonb AS eligibility_criteria,
            NULL::jsonb AS benefits,
            NULL::text AS brand_color,
            jsonb_build_object('redacao', sv.peso_redacao, 'matematica', sv.peso_matematica, 'linguagens', sv.peso_linguagens, 'humanas', sv.peso_ciencias_humanas, 'natureza', sv.peso_ciencias_natureza) AS weights,
            sis.acronym AS institution_acronym,
            cp.latitude AS latitude,
            cp.longitude AS longitude
           FROM public.opportunities o
             JOIN public.programs p ON p.type = 'sisu' AND p.status IN ('incoming', 'opened')
             JOIN public.courses c ON c.id = o.course_id
             JOIN public.campus cp ON cp.id = c.campus_id
             JOIN public.institutions i ON i.id = cp.institution_id
             LEFT JOIN ( SELECT opportunities.course_id,
                    min(opportunities.cutoff_score) AS min_cutoff,
                    max(opportunities.cutoff_score) AS max_cutoff
                   FROM public.opportunities
                  WHERE opportunities.opportunity_type = 'sisu'::text
                  GROUP BY opportunities.course_id) s ON s.course_id = o.course_id
             LEFT JOIN LATERAL ( SELECT d.start_date,
                    d.end_date
                   FROM public.important_dates d
                  WHERE d.type = 'sisu'::text AND d.controls_opportunity_dates = true
                  ORDER BY d.start_date DESC
                 LIMIT 1) id_dates ON true
             LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
             LEFT JOIN public.institutionsinfoemec ie ON ie.institution_id = i.id
             LEFT JOIN public.institutionsinfosisu sis ON sis.institution_id = i.id
          WHERE o.opportunity_type = 'sisu'::text AND o.year = p.cycle_year AND o.semester = p.cycle_semester
          ORDER BY c.id, o.created_at) sisu_branch
UNION ALL
 SELECT prouni_branch.unified_id,
    prouni_branch.title,
    prouni_branch.provider_name,
    prouni_branch.type,
    prouni_branch.opportunity_type,
    prouni_branch.category,
    prouni_branch.is_partner,
    prouni_branch.location,
    prouni_branch.badges,
    prouni_branch.created_at,
    prouni_branch.external_redirect_url,
    prouni_branch.external_redirect_enabled,
    prouni_branch.status,
    prouni_branch.starts_at,
    prouni_branch.ends_at,
    prouni_branch.match_score,
    prouni_branch.min_cutoff_score,
    prouni_branch.max_cutoff_score,
    prouni_branch.institution_cover_url,
    prouni_branch.nu_vagas_autorizadas,
    prouni_branch.qt_vagas_ofertadas,
    prouni_branch.qt_inscricao_prev,
    prouni_branch.vagas_ociosas_prev,
    prouni_branch.institution_id,
    prouni_branch.institution_igc,
    prouni_branch.institution_organization,
    prouni_branch.institution_category,
    prouni_branch.institution_site,
    prouni_branch.eligibility_criteria,
    prouni_branch.benefits,
    prouni_branch.brand_color,
    prouni_branch.weights,
    prouni_branch.institution_acronym,
    prouni_branch.latitude,
    prouni_branch.longitude
   FROM ( SELECT DISTINCT ON (c.id) 'mec_'::text || c.id::text AS unified_id,
            c.course_name AS title,
            i.name AS provider_name,
            'prouni'::text AS type,
            'prouni'::text AS opportunity_type,
            'grants_scholarships'::text AS category,
            false AS is_partner,
            (cp.city || ', '::text) || cp.state AS location,
            jsonb_build_array('100% Gratuito', o.shift) - 'null'::text AS badges,
            o.created_at,
            NULL::text AS external_redirect_url,
            false AS external_redirect_enabled,
            'approved'::text AS status,
            id_dates.start_date AS starts_at,
            id_dates.end_date AS ends_at,
            NULL::numeric AS match_score,
            s.min_cutoff AS min_cutoff_score,
            s.max_cutoff AS max_cutoff_score,
            NULL::text AS institution_cover_url,
            NULL::text AS nu_vagas_autorizadas,
            pv_agg.qt_vagas_ofertadas,
            NULL::text AS qt_inscricao_prev,
            pv_agg.vagas_ociosas_prev,
            i.id AS institution_id,
            ie.igc AS institution_igc,
            ie.academic_organization AS institution_organization,
            ie.administrative_category AS institution_category,
            ie.site AS institution_site,
            NULL::jsonb AS eligibility_criteria,
            NULL::jsonb AS benefits,
            NULL::text AS brand_color,
            NULL::jsonb AS weights,
            sis.acronym AS institution_acronym,
            cp.latitude AS latitude,
            cp.longitude AS longitude
           FROM public.opportunities o
             JOIN public.programs p ON p.type = 'prouni' AND p.status IN ('incoming', 'opened')
             JOIN public.courses c ON c.id = o.course_id
             JOIN public.campus cp ON cp.id = c.campus_id
             JOIN public.institutions i ON i.id = cp.institution_id
             LEFT JOIN ( SELECT opportunities.course_id,
                    min(opportunities.cutoff_score) AS min_cutoff,
                    max(opportunities.cutoff_score) AS max_cutoff
                   FROM public.opportunities
                  WHERE opportunities.opportunity_type = 'prouni'::text
                  GROUP BY opportunities.course_id) s ON s.course_id = o.course_id
             LEFT JOIN LATERAL ( SELECT d.start_date,
                    d.end_date
                   FROM public.important_dates d
                  WHERE d.type = 'prouni'::text AND d.controls_opportunity_dates = true
                  ORDER BY d.start_date DESC
                 LIMIT 1) id_dates ON true
             LEFT JOIN LATERAL ( SELECT sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
                    sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada))::integer AS vagas_ociosas_prev
                   FROM public.opportunities_prouni_vacancies pv
                  WHERE pv.opportunity_id = o.id) pv_agg ON true
             LEFT JOIN public.institutionsinfoemec ie ON ie.institution_id = i.id
             LEFT JOIN public.institutionsinfosisu sis ON sis.institution_id = i.id
          WHERE o.opportunity_type = 'prouni'::text AND o.year = p.cycle_year AND o.semester = p.cycle_semester
          ORDER BY c.id, o.created_at) prouni_branch
UNION ALL
 SELECT 'partner_'::text || po.id::text AS unified_id,
    po.name AS title,
    i.name AS provider_name,
    'partner'::text AS type,
    po.opportunity_type,
    'educational_programs'::text AS category,
    true AS is_partner,
    'Nacional'::text AS location,
    COALESCE(po.eligibility_criteria -> 'badges'::text, '[]'::jsonb) AS badges,
    po.created_at,
    po.external_redirect_config ->> 'url'::text AS external_redirect_url,
    COALESCE((po.external_redirect_config ->> 'enabled'::text)::boolean, false) AS external_redirect_enabled,
    po.status::text AS status,
    po.starts_at,
    po.ends_at,
    NULL::numeric AS match_score,
    NULL::numeric AS min_cutoff_score,
    NULL::numeric AS max_cutoff_score,
    pi.cover_url AS institution_cover_url,
    NULL::text AS nu_vagas_autorizadas,
    NULL::text AS qt_vagas_ofertadas,
    NULL::text AS qt_inscricao_prev,
    NULL::integer AS vagas_ociosas_prev,
    i.id AS institution_id,
    ie.igc AS institution_igc,
    ie.academic_organization AS institution_organization,
    ie.administrative_category AS institution_category,
    ie.site AS institution_site,
    po.eligibility_criteria,
    NULL::jsonb AS benefits,
    pi.brand_color,
    NULL::jsonb AS weights,
    sis.acronym AS institution_acronym,
    NULL::double precision AS latitude,
    NULL::double precision AS longitude
   FROM public.partner_opportunities po
     JOIN public.institutions i ON i.id = po.institution_id
     LEFT JOIN public.partner_institutions pi ON pi.institution_id = i.id
     LEFT JOIN public.institutionsinfoemec ie ON ie.institution_id = i.id
     LEFT JOIN public.institutionsinfosisu sis ON sis.institution_id = i.id
  WHERE po.status::text IN ('incoming'::text, 'opened'::text, 'closed'::text);

-- Recreate Indices for v_unified_opportunities
CREATE UNIQUE INDEX IF NOT EXISTS idx_v_unified_opportunities_id ON public.v_unified_opportunities (unified_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_institution ON public.v_unified_opportunities (institution_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_type ON public.v_unified_opportunities (type);

GRANT SELECT ON public.v_unified_opportunities TO anon, authenticated, service_role;

-- 8. Recreate View: v_unified_institutions (depends on v_unified_opportunities)
CREATE OR REPLACE VIEW public.v_unified_institutions AS
 WITH inst_opps AS (
         SELECT v_unified_opportunities.institution_id,
            array_agg(DISTINCT v_unified_opportunities.opportunity_type) AS opp_types
           FROM public.v_unified_opportunities
          GROUP BY v_unified_opportunities.institution_id
        )
 SELECT i.id,
    i.name,
    COALESCE(pi.location,
        CASE
            WHEN ie.city IS NOT NULL AND ie.state IS NOT NULL THEN (ie.city || ' - '::text) || ie.state
            WHEN ie.city IS NOT NULL THEN ie.city
            WHEN ie.state IS NOT NULL THEN ie.state
            ELSE ( SELECT (c.city || ' - '::text) || c.state
               FROM public.campus c
              WHERE c.institution_id = i.id AND c.city IS NOT NULL
             LIMIT 1)
        END) AS location,
    pi.logo_url,
    pi.cover_url,
    pi.brand_color,
    pi.description,
    pi.website_url,
    sisu.acronym,
        CASE
            WHEN i.is_partner IS TRUE THEN 'partner'::text
            ELSE 'mec'::text
        END AS type,
    io.opp_types,
    COALESCE(sisu.academic_organization, ie.academic_organization) AS academic_organization,
    COALESCE(sisu.administrative_category, ie.administrative_category) AS administrative_category
   FROM public.institutions i
     LEFT JOIN public.partner_institutions pi ON pi.institution_id = i.id
     LEFT JOIN public.institutionsinfoemec ie ON ie.institution_id = i.id
     LEFT JOIN public.institutionsinfosisu sisu ON sisu.institution_id = i.id
     LEFT JOIN inst_opps io ON io.institution_id = i.id;

GRANT SELECT ON public.v_unified_institutions TO anon, authenticated, service_role;

-- 9. Recreate Function: get_unified_opportunities_by_distance
CREATE OR REPLACE FUNCTION public.get_unified_opportunities_by_distance(
  p_lat DOUBLE PRECISION,
  p_long DOUBLE PRECISION
)
RETURNS TABLE (
    unified_id TEXT,
    title TEXT,
    provider_name TEXT,
    type TEXT,
    opportunity_type TEXT,
    category TEXT,
    is_partner BOOLEAN,
    location TEXT,
    badges JSONB,
    created_at TIMESTAMPTZ,
    external_redirect_url TEXT,
    external_redirect_enabled BOOLEAN,
    status TEXT,
    starts_at TIMESTAMPTZ,
    ends_at TIMESTAMPTZ,
    match_score NUMERIC,
    min_cutoff_score NUMERIC,
    max_cutoff_score NUMERIC,
    institution_cover_url TEXT,
    nu_vagas_autorizadas TEXT,
    qt_vagas_ofertadas TEXT,
    qt_inscricao_prev TEXT,
    vagas_ociosas_prev INTEGER,
    institution_id UUID,
    institution_igc TEXT,
    institution_organization TEXT,
    institution_category TEXT,
    institution_site TEXT,
    eligibility_criteria JSONB,
    benefits JSONB,
    brand_color TEXT,
    weights JSONB,
    institution_acronym TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    distance_km NUMERIC
)
LANGUAGE sql
STABLE
AS $$
  SELECT 
    v.unified_id,
    v.title,
    v.provider_name,
    v.type,
    v.opportunity_type,
    v.category,
    v.is_partner,
    v.location,
    v.badges,
    v.created_at,
    v.external_redirect_url,
    v.external_redirect_enabled,
    v.status,
    v.starts_at,
    v.ends_at,
    v.match_score,
    v.min_cutoff_score,
    v.max_cutoff_score,
    v.institution_cover_url,
    v.nu_vagas_autorizadas,
    v.qt_vagas_ofertadas,
    v.qt_inscricao_prev,
    v.vagas_ociosas_prev,
    v.institution_id,
    v.institution_igc,
    v.institution_organization,
    v.institution_category,
    v.institution_site,
    v.eligibility_criteria,
    v.benefits,
    v.brand_color,
    v.weights,
    v.institution_acronym,
    v.latitude,
    v.longitude,
    CASE 
      WHEN v.latitude IS NULL OR v.longitude IS NULL THEN 0
      WHEN p_lat IS NULL OR p_long IS NULL THEN 0
      ELSE public.haversine_km(p_lat, p_long, v.latitude, v.longitude)
    END AS distance_km
  FROM public.v_unified_opportunities v
$$;

GRANT EXECUTE ON FUNCTION public.get_unified_opportunities_by_distance(double precision, double precision) TO anon, authenticated, service_role;

-- 10. Recreate Materialized View: mv_course_catalog (year-agnostic)
CREATE MATERIALIZED VIEW public.mv_course_catalog AS
 WITH opportunity_aggregates AS (
         SELECT o.course_id,
            min(o.cutoff_score) AS min_cutoff,
            max(o.cutoff_score) AS max_cutoff,
            bool_or((o.opportunity_type = 'sisu'::text)) AS has_sisu,
            bool_or((o.opportunity_type = 'prouni'::text)) AS has_prouni,
            bool_or(((o.shift ~~* '%EAD%'::text) OR (o.shift ~~* '%distância%'::text))) AS has_ead,
            bool_or(((o.is_nubo_pick = true) OR (COALESCE(osv.vagas_ociosas_prev, 0) > 0))) AS has_nubo_pick,
            bool_or((EXISTS ( SELECT 1
                   FROM jsonb_array_elements(o.concurrency_tags) tags_group(value)
                  WHERE (EXISTS ( SELECT 1
                           FROM jsonb_array_elements_text(tags_group.value) tag(value)
                          WHERE (tag.value <> ALL (ARRAY['AMPLA_CONCORRENCIA'::text, 'MILITAR'::text, 'OUTROS'::text, 'BOLSA_PARCIAL'::text, 'BOLSA_INTEGRAL'::text]))))))) AS has_affirmative_action_tags,
            json_agg(json_build_object('id', o.id, 'shift', o.shift, 'scholarship_type', o.scholarship_type, 'concurrency_type', o.concurrency_type, 'concurrency_tags', o.concurrency_tags, 'scholarship_tags', o.scholarship_tags, 'opportunity_type', o.opportunity_type, 'cutoff_score', o.cutoff_score, 'is_nubo_pick', ((o.is_nubo_pick = true) OR (COALESCE(osv.vagas_ociosas_prev, 0) > 0)))) AS opportunities_json
           FROM public.opportunities o
             JOIN public.programs p ON p.type = o.opportunity_type AND p.status IN ('incoming', 'opened')
             LEFT JOIN public.opportunities_sisu_vacancies osv ON (osv.opportunity_id = o.id)
          WHERE o.year = p.cycle_year AND o.semester = p.cycle_semester 
            AND ((o.opportunity_type <> 'sisu'::text) OR (osv.qt_vagas_ofertadas IS NULL) OR ((replace(replace(TRIM(BOTH FROM osv.qt_vagas_ofertadas), '.'::text, ''::text), ','::text, '.'::text))::numeric > (0)::numeric))
          GROUP BY o.course_id
        )
 SELECT c.id AS course_id,
    c.course_name,
    i.name AS institution_name,
    cp.city,
    cp.state,
    cp.latitude,
    cp.longitude,
    c.vacancies AS vacancies_json,
    COALESCE(em.igc, '0'::text) AS igc_raw,
        CASE
            WHEN (em.igc = ANY (ARRAY['1'::text, '2'::text, '3'::text, '4'::text, '5'::text])) THEN (em.igc)::numeric
            ELSE (0)::numeric
        END AS igc_value,
    oa.min_cutoff,
    oa.max_cutoff,
    COALESCE(oa.has_sisu, false) AS has_sisu,
    COALESCE(oa.has_prouni, false) AS has_prouni,
    COALESCE(oa.has_ead, false) AS has_ead,
    COALESCE(oa.has_nubo_pick, false) AS has_nubo_pick,
    (COALESCE(oa.has_affirmative_action_tags, false) OR (( SELECT COALESCE(sum(((elem.value ->> 'quotas_offered'::text))::numeric), (0)::numeric) AS "coalesce"
           FROM jsonb_array_elements(c.vacancies) elem(value)) > (1)::numeric)) AS has_affirmative_action,
    COALESCE(oa.opportunities_json, '[]'::json) AS opportunities_json,
    to_tsvector('portuguese'::regconfig, ((((unaccent(c.course_name) || ' '::text) || unaccent(i.name)) || ' '::text) || unaccent(cp.city))) AS search_vector
   FROM public.courses c
     JOIN public.campus cp ON c.campus_id = cp.id
     JOIN public.institutions i ON cp.institution_id = i.id
     LEFT JOIN public.institutionsinfoemec em ON i.id = em.institution_id
     JOIN opportunity_aggregates oa ON c.id = oa.course_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_course_catalog_id ON public.mv_course_catalog (course_id);
GRANT SELECT ON public.mv_course_catalog TO anon, authenticated, service_role;

-- 11. Implement Year-Agnostic RPC: etl_import_prouni_base
CREATE OR REPLACE FUNCTION public.etl_import_prouni_base(p_program_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_course_id         UUID;
BEGIN
  -- Fetch program details
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  -- Start log
  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'prouni_base', 'running', now())
  RETURNING id INTO v_log_id;

  -- Loop through rawprouni
  FOR v_rec IN SELECT * FROM public.rawprouni
  LOOP
    BEGIN
      -- Resolve course_id
      SELECT c.id INTO v_course_id
      FROM public.courses c
      JOIN public.campus ca ON ca.id = c.campus_id
      WHERE ca.external_code = v_rec."CODIGO_CAMPUS"::text
        AND c.course_code = v_rec."CODIGO_CURSO"::text
      LIMIT 1;

      IF v_course_id IS NULL THEN
        CONTINUE;
      END IF;

      -- Insert opportunity
      INSERT INTO public.opportunities (
        course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data
      )
      VALUES (
        v_course_id,
        v_rec."SEMESTRE"::text,
        v_rec."CO_TURNO",
        v_rec."TIPO_BOLSA",
        v_year,
        'prouni',
        CASE 
          WHEN v_rec."NOTA_DE_CORTE" IS NULL OR TRIM(v_rec."NOTA_DE_CORTE") = '' THEN NULL
          ELSE REPLACE(REPLACE(TRIM(v_rec."NOTA_DE_CORTE"), '.', ''), ',', '.')::numeric
        END,
        to_jsonb(v_rec)
      )
      ON CONFLICT (course_id, opportunity_type, year, semester, shift)
      DO UPDATE SET
        cutoff_score = EXCLUDED.cutoff_score,
        raw_data = EXCLUDED.raw_data,
        updated_at = now();

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN
        v_errors := SQLERRM;
      ELSE
        v_errors := v_errors || '; ' || SQLERRM;
      END IF;
    END;
  END LOOP;

  -- Fix Scholarship Tags
  UPDATE public.opportunities
  SET scholarship_tags = '[["BOLSA_INTEGRAL"]]'::jsonb
  WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester
    AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0)
    AND (UPPER(scholarship_type) LIKE '%INTEGRAL%' OR UPPER(scholarship_type) = 'BOLSA INTEGRAL');

  UPDATE public.opportunities
  SET scholarship_tags = '[["BOLSA_PARCIAL"]]'::jsonb
  WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester
    AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0)
    AND (UPPER(scholarship_type) LIKE '%PARCIAL%' OR UPPER(scholarship_type) LIKE '%50%' OR UPPER(scholarship_type) = 'BOLSA PARCIAL 50%');

  -- Update log
  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'success', records_processed = v_processed, finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_prouni_base(uuid) TO service_role, authenticated;

-- 12. Implement Year-Agnostic RPC: etl_import_prouni_vacancies (includes cast fix)
CREATE OR REPLACE FUNCTION public.etl_import_prouni_vacancies(p_program_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_opp_id            UUID;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'prouni_vacancies', 'running', now())
  RETURNING id INTO v_log_id;

  FOR v_rec IN 
    SELECT 
      v."CO_CURSO"::text AS co_curso,
      v."CO_CAMPUS"::text AS co_campus,
      v."DS_TIPO_BOLSA",
      COALESCE(v."BOLSAS_AMPLA_OFERTADA"::integer, 0) AS bolsas_ampla_ofertada,
      COALESCE(v."BOLSAS_COTA_OFERTADA"::integer, 0) AS bolsas_cota_ofertada
    FROM public.rawprounivacancies v
  LOOP
    BEGIN
      SELECT op.id INTO v_opp_id
      FROM public.opportunities op
      JOIN public.courses c ON c.id = op.course_id
      JOIN public.campus ca ON ca.id = c.campus_id
      WHERE c.course_code = v_rec.co_curso
        AND ca.external_code = v_rec.co_campus
        AND op.opportunity_type = 'prouni'
        AND op.year = v_year
        AND op.semester = v_semester
      LIMIT 1;

      IF v_opp_id IS NULL THEN
        CONTINUE;
      END IF;

      INSERT INTO public.opportunities_prouni_vacancies (
        opportunity_id, ds_tipo_bolsa,
        bolsas_ampla_ofertada, bolsas_cota_ofertada,
        year, semester
      )
      VALUES (
        v_opp_id, v_rec."DS_TIPO_BOLSA",
        v_rec.bolsas_ampla_ofertada, v_rec.bolsas_cota_ofertada,
        v_year, v_semester
      )
      ON CONFLICT (opportunity_id, ds_tipo_bolsa)
      DO UPDATE SET
        bolsas_ampla_ofertada = EXCLUDED.bolsas_ampla_ofertada,
        bolsas_cota_ofertada  = EXCLUDED.bolsas_cota_ofertada,
        updated_at            = now();

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN
        v_errors := SQLERRM;
      ELSE
        v_errors := v_errors || '; ' || SQLERRM;
      END IF;
    END;
  END LOOP;

  -- Update course vacancies JSONB
  WITH aggregated_data AS (
    SELECT 
      c.id AS course_id,
      jsonb_agg(jsonb_build_object(
        'scholarship_type', pv.ds_tipo_bolsa,
        'broad_competition_offered', pv.bolsas_ampla_ofertada,
        'quotas_offered', pv.bolsas_cota_ofertada
      )) as vacancies_json
    FROM public.opportunities_prouni_vacancies pv
    JOIN public.opportunities o ON o.id = pv.opportunity_id
    JOIN public.courses c ON c.id = o.course_id
    WHERE o.year = v_year AND o.semester = v_semester
    GROUP BY c.id
  )
  UPDATE public.courses c
  SET vacancies = ad.vacancies_json
  FROM aggregated_data ad
  WHERE c.id = ad.course_id;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'success', records_processed = v_processed, finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_prouni_vacancies(uuid) TO service_role, authenticated;

-- 13. Implement Year-Agnostic RPC: etl_import_prouni_occupied (includes cast fix)
CREATE OR REPLACE FUNCTION public.etl_import_prouni_occupied(p_program_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_opp_id            UUID;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'prouni_occupied', 'running', now())
  RETURNING id INTO v_log_id;

  FOR v_rec IN 
    SELECT 
      o."CO_CURSO"::text AS co_curso,
      o."CO_CAMPUS"::text AS co_campus,
      o."DS_TIPO_BOLSA",
      COALESCE(o."BOLSAS_AMPLA_OCUPADA"::integer, 0) AS bolsas_ampla_ocupada,
      COALESCE(o."BOLSAS_COTA_OCUPADA"::integer, 0) AS bolsas_cota_ocupada
    FROM public.rawprouniocuppied o
  LOOP
    BEGIN
      SELECT op.id INTO v_opp_id
      FROM public.opportunities op
      JOIN public.courses c ON c.id = op.course_id
      JOIN public.campus ca ON ca.id = c.campus_id
      WHERE c.course_code = v_rec.co_curso
        AND ca.external_code = v_rec.co_campus
        AND op.opportunity_type = 'prouni'
        AND op.year = v_year
        AND op.semester = v_semester
      LIMIT 1;

      IF v_opp_id IS NULL THEN
        CONTINUE;
      END IF;

      INSERT INTO public.opportunities_prouni_vacancies (
        opportunity_id, ds_tipo_bolsa,
        bolsas_ampla_ocupada, bolsas_cota_ocupada,
        year, semester
      )
      VALUES (
        v_opp_id, v_rec."DS_TIPO_BOLSA",
        v_rec.bolsas_ampla_ocupada, v_rec.bolsas_cota_ocupada,
        v_year, v_semester
      )
      ON CONFLICT (opportunity_id, ds_tipo_bolsa)
      DO UPDATE SET
        bolsas_ampla_ocupada = EXCLUDED.bolsas_ampla_ocupada,
        bolsas_cota_ocupada  = EXCLUDED.bolsas_cota_ocupada,
        updated_at           = now();

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN
        v_errors := SQLERRM;
      ELSE
        v_errors := v_errors || '; ' || SQLERRM;
      END IF;
    END;
  END LOOP;

  -- Update course occupied and idle JSONB
  WITH aggregated_data AS (
    SELECT 
      c.id AS course_id,
      jsonb_agg(jsonb_build_object(
        'scholarship_type', pv.ds_tipo_bolsa,
        'broad_competition_occupied', pv.bolsas_ampla_ocupada,
        'quotas_occupied', pv.bolsas_cota_ocupada
      )) as occupied_json,
      jsonb_agg(jsonb_build_object(
        'scholarship_type', pv.ds_tipo_bolsa,
        'broad_competition_idle', GREATEST(0, pv.bolsas_ampla_ofertada - pv.bolsas_ampla_ocupada),
        'quotas_idle', GREATEST(0, pv.bolsas_cota_ofertada - pv.bolsas_cota_ocupada)
      )) as idle_json
    FROM public.opportunities_prouni_vacancies pv
    JOIN public.opportunities o ON o.id = pv.opportunity_id
    JOIN public.courses c ON c.id = o.course_id
    WHERE o.year = v_year AND o.semester = v_semester
    GROUP BY c.id
  )
  UPDATE public.courses c
  SET occupied = ad.occupied_json,
      vagas_ociosas_prev = ad.idle_json
  FROM aggregated_data ad
  WHERE c.id = ad.course_id;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'success', records_processed = v_processed, finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_prouni_occupied(uuid) TO service_role, authenticated;

-- 14. Implement Year-Agnostic RPC: etl_import_sisu_base
CREATE OR REPLACE FUNCTION public.etl_import_sisu_base(p_program_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
BEGIN
  -- Fetch program details
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  -- Start log
  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'sisu_base', 'running', now())
  RETURNING id INTO v_log_id;

  -- 1. Insert/Update Institutions
  FOR v_rec IN 
    SELECT DISTINCT "CO_IES"::text AS external_code, "NO_IES" AS name
    FROM public.rawsisuvacancies WHERE "CO_IES" IS NOT NULL
  LOOP
    BEGIN
      INSERT INTO public.institutions (external_code, name)
      VALUES (v_rec.external_code, v_rec.name)
      ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- 2. Insert/Update Campus
  FOR v_rec IN 
    SELECT DISTINCT 
      s."CO_IES"::text AS inst_external_code, 
      s."NO_CAMPUS" AS name,
      s."NO_MUNICIPIO_CAMPUS" AS municipio,
      s."SG_UF_CAMPUS" AS state, 
      s."DS_REGIAO" AS region
    FROM public.rawsisuvacancies s
    WHERE s."CO_IES" IS NOT NULL AND s."NO_CAMPUS" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.campus (institution_id, name, city, state, region)
        VALUES (
          v_inst_id,
          v_rec.name,
          COALESCE((SELECT c.name FROM public.cities c WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(v_rec.municipio)) AND c.state = v_rec.state LIMIT 1), v_rec.municipio),
          v_rec.state,
          v_rec.region
        )
        ON CONFLICT (institution_id, name, city) DO UPDATE SET
          state = EXCLUDED.state,
          region = EXCLUDED.region;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- 3. Insert/Update Courses
  FOR v_rec IN 
    SELECT DISTINCT 
      s."CO_IES"::text AS inst_external_code, 
      s."NO_CAMPUS" AS campus_name,
      s."NO_MUNICIPIO_CAMPUS" AS city_name,
      s."CO_IES_CURSO"::text AS course_code, 
      s."NO_CURSO" AS course_name
    FROM public.rawsisuvacancies s
    WHERE s."CO_IES" IS NOT NULL AND s."NO_CAMPUS" IS NOT NULL AND s."CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT ca.id INTO v_campus_id
      FROM public.campus ca
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name = v_rec.campus_name
        AND ca.city = v_rec.city_name
      LIMIT 1;

      IF v_campus_id IS NOT NULL THEN
        INSERT INTO public.courses (campus_id, course_code, course_name)
        VALUES (v_campus_id, v_rec.course_code, v_rec.course_name)
        ON CONFLICT (campus_id, course_code) DO UPDATE SET
          course_name = EXCLUDED.course_name;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- 4. Insert Opportunities
  FOR v_rec IN 
    SELECT 
      s."CO_IES"::text AS inst_external_code, 
      s."NO_CAMPUS" AS campus_name,
      s."CO_IES_CURSO"::text AS course_code,
      s."DS_TURNO" AS shift,
      s."DS_MOD_CONCORRENCIA" AS concurrency_type,
      s
    FROM public.rawsisuvacancies s
    WHERE s."CO_IES" IS NOT NULL AND s."NO_CAMPUS" IS NOT NULL AND s."CO_IES_CURSO" IS NOT NULL
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id
      FROM public.courses c
      JOIN public.campus ca ON ca.id = c.campus_id
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name = v_rec.campus_name
        AND c.course_code = v_rec.course_code
      LIMIT 1;

      IF v_course_id IS NOT NULL THEN
        INSERT INTO public.opportunities (
          course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, raw_data
        )
        VALUES (
          v_course_id,
          v_semester,
          v_rec.shift,
          v_rec.concurrency_type,
          (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = v_rec.concurrency_type LIMIT 1),
          v_year,
          'sisu',
          to_jsonb(v_rec.s)
        )
        ON CONFLICT (course_id, opportunity_type, year, semester, shift)
        DO UPDATE SET
          concurrency_tags = EXCLUDED.concurrency_tags,
          raw_data = EXCLUDED.raw_data,
          updated_at = now();

        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- Update log
  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'success', records_processed = v_processed, finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_sisu_base(uuid) TO service_role, authenticated;

-- 15. Implement Year-Agnostic RPC: etl_import_sisu_vacancies
CREATE OR REPLACE FUNCTION public.etl_import_sisu_vacancies(p_program_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'sisu_vacancies', 'running', now())
  RETURNING id INTO v_log_id;

  -- Loop through opportunities raw_data for the program and populate opportunities_sisu_vacancies
  FOR v_rec IN 
    SELECT id, raw_data 
    FROM public.opportunities 
    WHERE opportunity_type = 'sisu' AND year = v_year AND semester = v_semester
  LOOP
    BEGIN
      INSERT INTO public.opportunities_sisu_vacancies (
        opportunity_id,
        qt_semestre,
        nu_vagas_autorizadas,
        qt_vagas_ofertadas,
        nu_percentual_bonus,
        tp_mod_concorrencia,
        tp_cota,
        ds_mod_concorrencia,
        peso_redacao,
        nota_minima_redacao,
        peso_linguagens,
        nota_minima_linguagens,
        peso_matematica,
        nota_minima_matematica,
        peso_ciencias_humanas,
        nota_minima_ciencias_humanas,
        peso_ciencias_natureza,
        nota_minima_ciencias_natureza,
        nu_media_minima_enem,
        perc_uf_ibge_ppi,
        perc_uf_ibge_pp,
        perc_uf_ibge_i,
        perc_uf_ibge_q,
        perc_uf_ibge_pcd,
        nu_perc_lei,
        nu_perc_ppi,
        nu_perc_pp,
        nu_perc_i,
        nu_perc_q,
        nu_perc_pcd
      )
      VALUES (
        v_rec.id,
        v_rec.raw_data->>'QT_SEMESTRE',
        v_rec.raw_data->>'NU_VAGAS_AUTORIZADAS',
        v_rec.raw_data->>'QT_VAGAS_OFERTADAS',
        v_rec.raw_data->>'NU_PERCENTUAL_BONUS',
        v_rec.raw_data->>'TP_MOD_CONCORRENCIA',
        v_rec.raw_data->>'TP_COTA',
        v_rec.raw_data->>'DS_MOD_CONCORRENCIA',
        COALESCE(NULLIF(v_rec.raw_data->>'PESO_REDACAO', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'NOTA_MINIMA_REDACAO', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'PESO_LINGUAGENS', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'NOTA_MINIMA_LINGUAGENS', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'PESO_MATEMATICA', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'NOTA_MINIMA_MATEMATICA', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'PESO_CIENCIAS_HUMANAS', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'NOTA_MINIMA_CIENCIAS_HUMANAS', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'PESO_CIENCIAS_NATUREZA', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'NOTA_MINIMA_CIENCIAS_NATUREZA', ''), '0')::numeric,
        COALESCE(NULLIF(v_rec.raw_data->>'NU_MEDIA_MINIMA_ENEM', ''), '0')::numeric,
        v_rec.raw_data->>'PERC_UF_IBGE_PPI',
        v_rec.raw_data->>'PERC_UF_IBGE_PP',
        v_rec.raw_data->>'PERC_UF_IBGE_I',
        v_rec.raw_data->>'PERC_UF_IBGE_Q',
        v_rec.raw_data->>'PERC_UF_IBGE_PCD',
        v_rec.raw_data->>'NU_PERC_LEI',
        v_rec.raw_data->>'NU_PERC_PPI',
        v_rec.raw_data->>'NU_PERC_PP',
        v_rec.raw_data->>'NU_PERC_i',
        v_rec.raw_data->>'NU_PERC_Q',
        v_rec.raw_data->>'NU_PERC_PCD'
      )
      ON CONFLICT (opportunity_id)
      DO UPDATE SET
        qt_semestre = EXCLUDED.qt_semestre,
        nu_vagas_autorizadas = EXCLUDED.nu_vagas_autorizadas,
        qt_vagas_ofertadas = EXCLUDED.qt_vagas_ofertadas,
        nu_percentual_bonus = EXCLUDED.nu_percentual_bonus,
        tp_mod_concorrencia = EXCLUDED.tp_mod_concorrencia,
        tp_cota = EXCLUDED.tp_cota,
        ds_mod_concorrencia = EXCLUDED.ds_mod_concorrencia,
        peso_redacao = EXCLUDED.peso_redacao,
        nota_minima_redacao = EXCLUDED.nota_minima_redacao,
        peso_linguagens = EXCLUDED.peso_linguagens,
        nota_minima_linguagens = EXCLUDED.nota_minima_linguagens,
        peso_matematica = EXCLUDED.peso_matematica,
        nota_minima_matematica = EXCLUDED.nota_minima_matematica,
        peso_ciencias_humanas = EXCLUDED.peso_ciencias_humanas,
        nota_minima_ciencias_humanas = EXCLUDED.nota_minima_ciencias_humanas,
        peso_ciencias_natureza = EXCLUDED.peso_ciencias_natureza,
        nota_minima_ciencias_natureza = EXCLUDED.nota_minima_ciencias_natureza,
        nu_media_minima_enem = EXCLUDED.nu_media_minima_enem,
        updated_at = now();

      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- Predictions & History Propagation (Copy from Year - 1)
  BEGIN
    -- Cutoff scores propagation
    UPDATE public.opportunities op_curr
    SET cutoff_score = op_prev.cutoff_score
    FROM public.opportunities op_prev
    WHERE op_curr.opportunity_type = 'sisu' AND op_curr.year = v_year AND op_curr.semester = v_semester
      AND op_prev.opportunity_type = 'sisu' AND op_prev.year = v_year - 1 AND op_prev.semester = v_semester
      AND op_curr.course_id = op_prev.course_id 
      AND op_curr.shift = op_prev.shift 
      AND op_curr.concurrency_type = op_prev.concurrency_type
      AND op_prev.cutoff_score IS NOT NULL 
      AND op_curr.cutoff_score IS NULL;

    -- Vacancies/Inscriptions data propagation
    UPDATE public.opportunities_sisu_vacancies osv_curr
    SET vagas_ociosas_prev = osv_prev.vagas_ociosas_prev,
        qt_inscricao_prev = osv_prev.qt_inscricao_prev,
        qt_vagas_ofertadas_prev = osv_prev.qt_vagas_ofertadas
    FROM public.opportunities o_curr
    JOIN public.opportunities o_prev ON o_prev.course_id = o_curr.course_id 
      AND o_prev.shift = o_curr.shift 
      AND o_prev.concurrency_type = o_curr.concurrency_type 
      AND o_prev.year = v_year - 1 
      AND o_prev.semester = v_semester
      AND o_prev.opportunity_type = 'sisu'
    JOIN public.opportunities_sisu_vacancies osv_prev ON osv_prev.opportunity_id = o_prev.id
    WHERE osv_curr.opportunity_id = o_curr.id 
      AND o_curr.year = v_year 
      AND o_curr.semester = v_semester 
      AND o_curr.opportunity_type = 'sisu';
  EXCEPTION WHEN OTHERS THEN
    IF v_errors IS NULL THEN v_errors := 'Propagation Error: ' || SQLERRM; ELSE v_errors := v_errors || '; Propagation Error: ' || SQLERRM; END IF;
  END;

  -- Update log
  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'success', records_processed = v_processed, finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_sisu_vacancies(uuid) TO service_role, authenticated;

-- 16. Implement Year-Agnostic RPC: etl_import_emec
CREATE OR REPLACE FUNCTION public.etl_import_emec()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_rec               RECORD;
  v_inst_id           UUID;
BEGIN
  -- Start log
  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (null, 'emec', 'running', now())
  RETURNING id INTO v_log_id;

  FOR v_rec IN 
    SELECT DISTINCT ON ("Código IES")
      "Código IES"::text AS inst_external_code,
      "Código Mantenedora" AS maintainer_code,
      "Razão Social" AS maintainer_name,
      "CNPJ",
      "Natureza Jurídica" AS legal_nature,
      "Telefone" AS phone,
      "Sitio" AS site,
      "e-Mail" AS email,
      "Endereço Sede" AS address_seat,
      "Município" AS city,
      "UF" AS state,
      "Organização Acadêmica" AS academic_organization,
      "Tipo de Credenciamento" AS credentialing_type,
      "Categoria Administrativa" AS administrative_category,
      "Data do Ato de Criação da IES" AS creation_date_str,
      "CI",
      "Ano CI" AS ci_year,
      "CI-EaD",
      "Ano CI-EaD" AS ci_ead_year,
      "IGC",
      "Ano IGC" AS igc_year,
      "Reitor/Dirigente Principal" AS rector,
      "Representante Legal" AS legal_representative,
      "Sinalizações Vigentes" AS current_signs,
      "Situação da IES" AS status
    FROM public.rawemec
    WHERE "Código IES" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;

      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutionsinfoemec (
          institution_id, maintainer_code, maintainer_name, cnpj, legal_nature, phone, site, email,
          address_seat, city, state, academic_organization, credentialing_type, administrative_category,
          creation_date, ci, ci_year, ci_ead, ci_ead_year, igc, igc_year, rector, legal_representative,
          current_signs, status
        )
        VALUES (
          v_inst_id,
          v_rec.maintainer_code,
          v_rec.maintainer_name,
          v_rec.cnpj,
          v_rec.legal_nature,
          v_rec.phone,
          v_rec.site,
          v_rec.email,
          v_rec.address_seat,
          v_rec.city,
          v_rec.state,
          v_rec.academic_organization,
          v_rec.credentialing_type,
          v_rec.administrative_category,
          CASE WHEN v_rec.creation_date_str ~ '^\d{4}-\d{2}-\d{2}$' THEN v_rec.creation_date_str::DATE ELSE NULL END,
          v_rec."CI",
          v_rec.ci_year,
          v_rec."CI-EaD",
          v_rec.ci_ead_year,
          v_rec."IGC",
          v_rec.igc_year,
          v_rec.rector,
          v_rec.legal_representative,
          v_rec.current_signs,
          v_rec.status
        )
        ON CONFLICT (institution_id)
        DO UPDATE SET
          maintainer_code = EXCLUDED.maintainer_code,
          maintainer_name = EXCLUDED.maintainer_name,
          cnpj = EXCLUDED.cnpj,
          legal_nature = EXCLUDED.legal_nature,
          phone = EXCLUDED.phone,
          site = EXCLUDED.site,
          email = EXCLUDED.email,
          address_seat = EXCLUDED.address_seat,
          city = EXCLUDED.city,
          state = EXCLUDED.state,
          academic_organization = EXCLUDED.academic_organization,
          credentialing_type = EXCLUDED.credentialing_type,
          administrative_category = EXCLUDED.administrative_category,
          creation_date = EXCLUDED.creation_date,
          ci = EXCLUDED.ci,
          ci_year = EXCLUDED.ci_year,
          ci_ead = EXCLUDED.ci_ead,
          ci_ead_year = EXCLUDED.ci_ead_year,
          igc = EXCLUDED.igc,
          igc_year = EXCLUDED.igc_year,
          rector = EXCLUDED.rector,
          legal_representative = EXCLUDED.legal_representative,
          current_signs = EXCLUDED.current_signs,
          status = EXCLUDED.status,
          updated_at = now();

        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF v_errors IS NULL THEN v_errors := SQLERRM; ELSE v_errors := v_errors || '; ' || SQLERRM; END IF;
    END;
  END LOOP;

  -- Update log
  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'success', records_processed = v_processed, finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_emec() TO service_role, authenticated;
