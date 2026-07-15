-- 20260708150000_repair_migration_registry_and_apply_hotfix.sql
--
-- REPAIR: Sincroniza supabase_migrations.schema_migrations com o estado real
-- do banco (migrations aplicadas manualmente sem registro), e aplica a hotfix
-- de search_text + search_opportunities que ainda não chegou ao banco.
-- ====================================================================================

-- ====================================================================================
-- PARTE 1: Registra migrations já aplicadas no banco mas ausentes do schema_migrations
-- ====================================================================================
INSERT INTO supabase_migrations.schema_migrations (version, name, statements) VALUES
  ('20260617000100', 'remove_admin_funnel_chart_view', NULL),
  ('20260617110600', 'fix_partner_funnel_view', NULL),
  ('20260617120000', 'fix_partners_click_foreign_key', NULL),
  ('20260617120100', 'fix_partners_users_foreign_key', NULL),
  ('20260617120200', 'fix_remaining_partner_foreign_keys', NULL),
  ('20260617120300', 'fix_partners_users_fk_to_institutions', NULL),
  ('20260617130000', 'add_get_partner_applications_by_institution', NULL),
  ('20260617130100', 'add_get_eligible_count_by_institution', NULL),
  ('20260617140000', 'backfill_eligibility_and_profile_mappings', NULL),
  ('20260617150000', 'fix_backfill_eligibility_and_mappings', NULL),
  ('20260617160000', 'add_eligibility_results_to_student_applications', NULL),
  ('20260617160100', 'update_backfill_to_save_to_applications', NULL),
  ('20260617170000', 'sync_eligibility_to_applications', NULL),
  ('20260617180000', 'fix_partner_applications_rpc_sources', NULL),
  ('20260617190000', 'auto_create_user_profile_trigger', NULL),
  ('20260625135100', 'add_pulsate_to_system_intents', NULL),
  ('20260625152200', 'configure_system_intents_pulsate', NULL),
  ('20260625190000', 'fix_system_intents_open_drawer', NULL),
  ('20260626000000', 'add_institution_favorites', NULL),
  ('20260626000001', 'update_submit_intent', NULL),
  ('20260626100000', 'fix_user_favorites_rls_insert', NULL),
  ('20260701000004', 'search_opportunities_rpc', NULL),
  ('20260703120000', 'unify_prouni_etl', NULL),
  ('20260703130824', 'fix_prouni_etl_duplicates', NULL),
  ('20260703133721', 'optimize_prouni_etl', NULL),
  ('20260703140534', 'stop_etl_log', NULL),
  ('20260703140830', 'fix_etl_stop_log', NULL),
  ('20260703150000', 'harden_prouni_etl', NULL),
  ('20260703160000', 'fix_matview_concurrent_refresh_indexes', NULL),
  ('20260703170000', 'prouni_cutoff_agnostic_parse', NULL),
  ('20260703180000', 'restore_v_unified_institutions_shape', NULL),
  ('20260703190000', 'drop_mv_course_catalog', NULL),
  ('20260703191000', 'drop_obsolete_manage_important_date_overloads', NULL),
  ('20260706120000', 'prouni_grain_and_null_cutoff', NULL),
  ('20260706121000', 'match_prouni_agnostic', NULL),
  ('20260706130000', 'restore_unified_views', NULL),
  ('20260707120000', 'add_vagas_ociosas_to_get_opportunities_for_user', NULL),
  ('20260707130000', 'match_pref_city_geo_and_ead', NULL),
  ('20260707140000', 'normalize_prouni_ead_shift', NULL),
  ('20260707150000', 'fix_orphan_ead_shift_preference', NULL),
  ('20260707160000', 'match_prouni_idle_and_cota', NULL),
  ('20260707170000', 'rebuild_prouni_2026_2_clone', NULL),
  ('20260707180000', 'fix_clone_grain_and_rebuild_2026_2', NULL),
  ('20260707190000', 'match_no_boost_on_gated', NULL),
  ('20260708100000', 'match_prouni_cota_ppi_only', NULL),
  ('20260708110000', 'fix_prouni_vacancies_sum_to_max', NULL),
  ('20260708120000', 'add_search_text_to_v_unified_opportunities', NULL),
  ('20260708130000', 'restore_v_unified_institutions', NULL),
  ('20260708140000', 'hotfix_recreate_search_opportunities', NULL)
ON CONFLICT (version) DO NOTHING;

-- ====================================================================================
-- PARTE 2: Aplica o hotfix de search_text + search_opportunities
-- (banco ainda tem matview SEM search_text e SEM a função search_opportunities)
-- ====================================================================================

DROP FUNCTION IF EXISTS public.search_opportunities(text);
DROP FUNCTION IF EXISTS public.get_unified_opportunities_by_distance(double precision, double precision);
DROP VIEW IF EXISTS public.v_unified_institutions;
DROP MATERIALIZED VIEW IF EXISTS public.v_unified_opportunities;

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
    pv_curr.qt_vagas_ofertadas AS qt_vagas_ofertadas_current,
    pv_prev.qt_vagas_ofertadas AS qt_vagas_ofertadas_prev,
    NULL::text AS qt_inscricao_current,
    NULL::text AS qt_inscricao_prev,
    NULL::numeric AS nu_media_minima_enem_current,
    NULL::numeric AS nu_media_minima_enem_prev,
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
    LEFT JOIN LATERAL (
      SELECT
        sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
        sum((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada)) AS vagas_ociosas
      FROM public.opportunities_prouni_vacancies pv
      JOIN public.opportunities opp ON opp.id = pv.opportunity_id
      WHERE opp.course_id = o.course_id AND opp.year = p.cycle_year AND opp.opportunity_type = 'prouni'
    ) pv_curr ON true
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
  ON public.v_unified_opportunities
  USING gin (search_text gin_trgm_ops);

CREATE OR REPLACE FUNCTION public.search_opportunities(p_q text)
RETURNS SETOF public.v_unified_opportunities
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT *
  FROM public.v_unified_opportunities
  WHERE search_text LIKE '%' || public.f_unaccent(p_q) || '%';
$$;

GRANT EXECUTE ON FUNCTION public.search_opportunities(text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_unified_opportunities_by_distance(
  p_lat double precision,
  p_long double precision
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
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
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

GRANT EXECUTE ON FUNCTION public.get_unified_opportunities_by_distance(double precision, double precision) TO authenticated, anon, service_role;

REFRESH MATERIALIZED VIEW CONCURRENTLY public.v_unified_opportunities;

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

NOTIFY pgrst, 'reload schema';
