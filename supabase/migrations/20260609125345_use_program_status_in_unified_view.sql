-- Fix to v_unified_opportunities
-- vagas_ociosas_current and vagas_ociosas_prev must return NULL instead of FALSE 
-- if there is no record with qt_inscricao in that cycle.

-- DROP MATERIALIZED VIEW IF EXISTS public.mv_course_catalog CASCADE;
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
      WHERE opp.opportunity_type = 'sisu' AND opp.course_id = o.course_id AND opp.year = (p.cycle_year - 1)
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
      WHERE op.course_id = o.course_id AND op.year = (p.cycle_year - 1) AND op.opportunity_type = 'sisu'
      LIMIT 1
    ) sv_prev ON true

    -- qt_inscricao_prev: pick one modality from prev cycle (they're per-modality; representative)
    LEFT JOIN LATERAL (
      SELECT sv.qt_inscricao
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.year = (p.cycle_year - 1) AND op.opportunity_type = 'sisu'
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
      WHERE op.course_id = o.course_id
        AND op.opportunity_type = 'sisu'
        AND op.year = (p.cycle_year - 1)
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
      WHERE opp.opportunity_type = 'prouni' AND opp.course_id = o.course_id AND opp.year = (p.cycle_year - 1)
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
      WHERE pv.course_id = o.course_id AND pv.year = (p.cycle_year - 1)
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
    -- Distance logic (Earth distance in KM)
    (6371 * acos(
      cos(radians(p_lat)) * cos(radians(v.latitude)) *
      cos(radians(v.longitude) - radians(p_long)) +
      sin(radians(p_lat)) * sin(radians(v.latitude))
    ))::NUMERIC AS distance_km
  FROM public.v_unified_opportunities v
  WHERE v.latitude IS NOT NULL AND v.longitude IS NOT NULL
  ORDER BY distance_km ASC;
$func$;
