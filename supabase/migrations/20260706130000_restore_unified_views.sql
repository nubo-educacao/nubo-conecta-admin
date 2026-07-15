-- 20260706130000_restore_unified_views.sql
-- RESTAURAÇÃO: uma execução concorrente do sprint recriou v_unified_opportunities com uma
-- definição ANTIGA/regredida (colunas qt_inscricao_2025, search_text, min/max_cutoff_score,
-- SEM branch ProUni) e DROPOU v_unified_institutions. Isso quebrou o app e as funções
-- consumidoras (get_opportunities_for_user, get_unified_opportunities_by_distance), que
-- esperam o shape enriquecido (_current/_prev, latitude/longitude).
--
-- Restaura as definições canônicas do repo:
--   - v_unified_opportunities enriquecida (migration 20260703120000), com branch ProUni via
--     opportunities_prouni_vacancies. Como o cutoff_score do ProUni agora é NULL (Card 2),
--     min/max_cutoff_score_* do ProUni saem NULL — alinhado a "ProUni sem nota de corte".
--   - Índice único (unified_id, type) para REFRESH ... CONCURRENTLY (ADR-0019 / migration 160000).
--   - get_unified_opportunities_by_distance (shape enriquecido).
--   - v_unified_institutions enriquecida (migration 20260703180000).
-- NÃO recria mv_course_catalog (removida por decisão — migration 190000).

DROP FUNCTION IF EXISTS public.get_unified_opportunities_by_distance(double precision, double precision) CASCADE;
DROP VIEW IF EXISTS public.v_unified_institutions;
DROP MATERIALIZED VIEW IF EXISTS public.v_unified_opportunities CASCADE;

-- ====================================================================================
-- 1. v_unified_opportunities (enriquecida)
-- ====================================================================================
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
    sv_curr.qt_inscricao       AS qt_inscricao_current,
    sv_prev_inscricao.qt_inscricao AS qt_inscricao_prev,
    sv_curr.nu_media_minima_enem AS nu_media_minima_enem_current,
    sv_prev.nu_media_minima_enem AS nu_media_minima_enem_prev,
    vc_curr.has_vagas_ociosas  AS vagas_ociosas_current,
    vc_prev.has_vagas_ociosas  AS vagas_ociosas_prev

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
    NULL::numeric AS nu_media_minima_enem_current,
    NULL::numeric AS nu_media_minima_enem_prev,
    (COALESCE(pv_curr.vagas_ociosas, 0) > 0)::boolean AS vagas_ociosas_current,
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
      WHERE opp.opportunity_type = 'prouni' AND opp.course_id = o.course_id AND opp.year = p.cycle_year - 1
    ) s_prev ON true

    LEFT JOIN LATERAL (
      SELECT d.start_date, d.end_date
      FROM public.important_dates d
      WHERE d.type = 'prouni' AND d.controls_opportunity_dates = true
      ORDER BY d.start_date DESC LIMIT 1
    ) id_dates ON true

    -- Vagas ProUni CURRENT: join via opportunities_prouni_vacancies 1:1 com opp
    LEFT JOIN LATERAL (
      SELECT
        sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
        sum((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada)) AS vagas_ociosas
      FROM public.opportunities_prouni_vacancies pv
      JOIN public.opportunities opp ON opp.id = pv.opportunity_id
      WHERE opp.course_id = o.course_id AND opp.year = p.cycle_year AND opp.opportunity_type = 'prouni'
    ) pv_curr ON true

    -- Vagas ProUni PREVIOUS
    LEFT JOIN LATERAL (
      SELECT
        sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
        sum((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada)) AS vagas_ociosas
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

-- ─────────── PARTNERS ───────────
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
  NULL::boolean  AS vagas_ociosas_prev
FROM public.partner_opportunities po
  JOIN public.institutions i ON i.id = po.institution_id
  LEFT JOIN public.partner_institutions pi ON pi.institution_id = i.id
  LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
  LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
WHERE po.status IN ('incoming', 'opened', 'closed');

GRANT SELECT ON public.v_unified_opportunities TO authenticated, anon, service_role;

-- Índice único p/ REFRESH ... CONCURRENTLY (unified_id, type é único: DISTINCT ON por branch)
CREATE UNIQUE INDEX uq_v_unified_opportunities_id_type
  ON public.v_unified_opportunities (unified_id, type);
CREATE INDEX idx_v_unified_opportunities_institution
  ON public.v_unified_opportunities (institution_id);

-- ====================================================================================
-- 2. get_unified_opportunities_by_distance (shape enriquecido)
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.get_unified_opportunities_by_distance(
  p_lat double precision,
  p_long double precision
)
RETURNS TABLE (
  unified_id text,
  title text,
  provider_name text,
  type text,
  opportunity_type text,
  category text,
  is_partner boolean,
  location text,
  badges jsonb,
  created_at timestamptz,
  external_redirect_url text,
  external_redirect_enabled boolean,
  status text,
  starts_at timestamptz,
  ends_at timestamptz,
  match_score numeric,
  institution_cover_url text,
  nu_vagas_autorizadas text,
  institution_id uuid,
  institution_igc text,
  institution_organization text,
  institution_category text,
  institution_site text,
  eligibility_criteria jsonb,
  benefits jsonb,
  brand_color text,
  weights jsonb,
  institution_acronym text,
  latitude double precision,
  longitude double precision,
  min_cutoff_score_current numeric,
  min_cutoff_score_prev numeric,
  max_cutoff_score_current numeric,
  max_cutoff_score_prev numeric,
  qt_vagas_ofertadas_current text,
  qt_vagas_ofertadas_prev text,
  qt_inscricao_current text,
  qt_inscricao_prev text,
  nu_media_minima_enem_current numeric,
  nu_media_minima_enem_prev numeric,
  vagas_ociosas_current boolean,
  vagas_ociosas_prev boolean,
  distance_km double precision
)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    v.*,
    CASE
      WHEN v.latitude IS NOT NULL AND v.longitude IS NOT NULL
           AND p_lat IS NOT NULL AND p_long IS NOT NULL THEN
        6371.0 * acos(
          LEAST(1.0, GREATEST(-1.0,
            cos(radians(p_lat)) * cos(radians(v.latitude)) *
            cos(radians(v.longitude) - radians(p_long)) +
            sin(radians(p_lat)) * sin(radians(v.latitude))
          ))
        )
      ELSE NULL
    END AS distance_km
  FROM public.v_unified_opportunities v;
$$;

GRANT EXECUTE ON FUNCTION public.get_unified_opportunities_by_distance(double precision, double precision) TO authenticated, anon, service_role;

-- ====================================================================================
-- 3. v_unified_institutions (enriquecida — migration 20260703180000)
-- ====================================================================================
CREATE VIEW public.v_unified_institutions AS
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
