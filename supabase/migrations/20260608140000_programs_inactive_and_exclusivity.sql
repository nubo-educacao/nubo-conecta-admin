-- 1. Alter public.programs status check constraint to include 'inactive'
ALTER TABLE public.programs DROP CONSTRAINT IF EXISTS programs_status_check;
ALTER TABLE public.programs ADD CONSTRAINT programs_status_check CHECK (status IN ('incoming', 'opened', 'closed', 'inactive'));

-- 2. Create the trigger function to ensure a single active program per type
CREATE OR REPLACE FUNCTION public.ensure_single_active_program()
RETURNS TRIGGER AS $$
BEGIN
  -- If the new/updated program is active (incoming, opened, closed), set all others of same type to 'inactive'
  IF NEW.status IN ('incoming', 'opened', 'closed') THEN
    UPDATE public.programs
    SET status = 'inactive',
        updated_at = now()
    WHERE type = NEW.type
      AND id <> NEW.id
      AND status IN ('incoming', 'opened', 'closed');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. Create AFTER trigger on public.programs
DROP TRIGGER IF EXISTS trigger_ensure_single_active_program ON public.programs;
CREATE TRIGGER trigger_ensure_single_active_program
AFTER INSERT OR UPDATE OF status ON public.programs
FOR EACH ROW
EXECUTE FUNCTION public.ensure_single_active_program();

-- 4. Drop dependent views/functions to avoid dependency errors
DROP MATERIALIZED VIEW IF EXISTS public.mv_course_catalog CASCADE;
DROP VIEW IF EXISTS public.v_unified_institutions CASCADE;
DROP FUNCTION IF EXISTS public.get_unified_opportunities_by_distance CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.v_unified_opportunities CASCADE;

-- 5. Recreate v_unified_opportunities materialized view
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
   FROM ( SELECT DISTINCT ON (c.id) ('mec_'::text || (c.id)::text) AS unified_id,
            c.course_name AS title,
            i.name AS provider_name,
            'sisu'::text AS type,
            'sisu'::text AS opportunity_type,
            'public_universities'::text AS category,
            false AS is_partner,
            ((cp.city || ', '::text) || cp.state) AS location,
            (jsonb_build_array(o.shift) - 'null'::text) AS badges,
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
            cp.latitude,
            cp.longitude
           FROM public.opportunities o
             JOIN public.programs p ON p.type = 'sisu'::text AND p.status <> 'inactive'::text
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
             LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
             LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
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
   FROM ( SELECT DISTINCT ON (c.id) ('mec_'::text || (c.id)::text) AS unified_id,
            c.course_name AS title,
            i.name AS provider_name,
            'prouni'::text AS type,
            'prouni'::text AS opportunity_type,
            'grants_scholarships'::text AS category,
            false AS is_partner,
            ((cp.city || ', '::text) || cp.state) AS location,
            (jsonb_build_array('100% Gratuito', o.shift) - 'null'::text) AS badges,
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
            cp.latitude,
            cp.longitude
           FROM public.opportunities o
             JOIN public.programs p ON p.type = 'prouni'::text AND p.status <> 'inactive'::text
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
             LEFT JOIN LATERAL ( SELECT (sum((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)))::text AS qt_vagas_ofertadas,
                    (sum(((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) - (COALESCE(pv.bolsas_ampla_ocupada,0) + COALESCE(pv.bolsas_cota_ocupada,0)))))::integer AS vagas_ociosas_prev
                   FROM public.courses_prouni_vacancies pv
                  WHERE pv.course_id = c.id) pv_agg ON true
             LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
             LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
          WHERE o.opportunity_type = 'prouni'::text AND o.year = p.cycle_year AND o.semester = p.cycle_semester
          ORDER BY c.id, o.created_at) prouni_branch
UNION ALL
 SELECT ('partner_'::text || (po.id)::text) AS unified_id,
    po.name AS title,
    i.name AS provider_name,
    'partner'::text AS type,
    po.opportunity_type,
    'educational_programs'::text AS category,
    true AS is_partner,
    'Nacional'::text AS location,
    COALESCE((po.eligibility_criteria -> 'badges'::text), '[]'::jsonb) AS badges,
    po.created_at,
    (po.external_redirect_config ->> 'url'::text) AS external_redirect_url,
    COALESCE(((po.external_redirect_config ->> 'enabled'::text))::boolean, false) AS external_redirect_enabled,
    (po.status)::text AS status,
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
     LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
     LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
  WHERE po.status::text IN ('incoming'::text, 'opened'::text, 'closed'::text);

-- Recreate indices on v_unified_opportunities
CREATE UNIQUE INDEX IF NOT EXISTS idx_v_unified_opportunities_id ON public.v_unified_opportunities (unified_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_institution ON public.v_unified_opportunities (institution_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_type ON public.v_unified_opportunities (type);

GRANT SELECT ON public.v_unified_opportunities TO anon, authenticated, service_role;

-- 6. Recreate v_unified_institutions
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
            WHEN ((ie.city IS NOT NULL) AND (ie.state IS NOT NULL)) THEN ((ie.city || ' - '::text) || ie.state)
            WHEN (ie.city IS NOT NULL) THEN ie.city
            WHEN (ie.state IS NOT NULL) THEN ie.state
            ELSE ( SELECT ((c.city || ' - '::text) || c.state)
               FROM public.campus c
              WHERE ((c.institution_id = i.id) AND (c.city IS NOT NULL))
             LIMIT 1)
        END) AS location,
    pi.logo_url,
    pi.cover_url,
    pi.brand_color,
    pi.description,
    pi.website_url,
    sisu.acronym,
        CASE
            WHEN (i.is_partner IS TRUE) THEN 'partner'::text
            ELSE 'mec'::text
        END AS type,
    io.opp_types,
    COALESCE(sisu.academic_organization, ie.academic_organization) AS academic_organization,
    COALESCE(sisu.administrative_category, ie.administrative_category) AS administrative_category
   FROM public.institutions i
     LEFT JOIN public.partner_institutions pi ON pi.institution_id = i.id
     LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
     LEFT JOIN public.institutions_info_sisu sisu ON sisu.institution_id = i.id
     LEFT JOIN inst_opps io ON io.institution_id = i.id;

GRANT SELECT ON public.v_unified_institutions TO anon, authenticated, service_role;

-- 7. Recreate mv_course_catalog
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
             JOIN public.programs p ON p.type = o.opportunity_type AND p.status <> 'inactive'::text
             LEFT JOIN public.opportunities_sisu_vacancies osv ON (osv.opportunity_id = o.id)
          WHERE o.year = p.cycle_year AND o.semester = p.cycle_semester 
            AND ((o.opportunity_type <> 'sisu'::text) OR (osv.qt_vagas_ofertadas IS NULL) OR ((replace(replace(TRIM(BOTH FROM osv.qt_vagas_ofertadas), '.'::text, ''::text), ','::text, '.'::text))::numeric > (0)::numeric))
          GROUP BY o.course_id
        ), prouni_vacancies_agg AS (
         SELECT pv.course_id,
            jsonb_agg(jsonb_build_object('scholarship_type', pv.ds_tipo_bolsa, 'broad_competition_offered', pv.bolsas_ampla_ofertada, 'quotas_offered', pv.bolsas_cota_ofertada)) AS vacancies_json,
            bool_or((pv.bolsas_cota_ofertada > 0)) AS has_affirmative_action
           FROM public.courses_prouni_vacancies pv
          GROUP BY pv.course_id
        )
 SELECT c.id AS course_id,
    c.course_name,
    i.name AS institution_name,
    cp.city,
    cp.state,
    cp.latitude,
    cp.longitude,
    COALESCE(pva.vacancies_json, '[]'::jsonb) AS vacancies_json,
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
    (COALESCE(oa.has_affirmative_action_tags, false) OR COALESCE(pva.has_affirmative_action, false)) AS has_affirmative_action,
    COALESCE(oa.opportunities_json, '[]'::json) AS opportunities_json,
    to_tsvector('portuguese'::regconfig, ((((unaccent(c.course_name) || ' '::text) || unaccent(i.name)) || ' '::text) || unaccent(cp.city))) AS search_vector
   FROM public.courses c
     JOIN public.campus cp ON c.campus_id = cp.id
     JOIN public.institutions i ON cp.institution_id = i.id
     LEFT JOIN public.institutions_info_emec em ON i.id = em.institution_id
     JOIN opportunity_aggregates oa ON c.id = oa.course_id
     LEFT JOIN prouni_vacancies_agg pva ON pva.course_id = c.id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_course_catalog_id ON public.mv_course_catalog (course_id);
GRANT SELECT ON public.mv_course_catalog TO anon, authenticated, service_role;

-- 8. Recreate get_unified_opportunities_by_distance
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
    distance_km DOUBLE PRECISION
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
      WHEN v.latitude IS NULL OR v.longitude IS NULL THEN 0::double precision
      WHEN p_lat IS NULL OR p_long IS NULL THEN 0::double precision
      ELSE public.haversine_km(p_lat, p_long, v.latitude, v.longitude)
    END AS distance_km
  FROM public.v_unified_opportunities v
$$;

GRANT EXECUTE ON FUNCTION public.get_unified_opportunities_by_distance(double precision, double precision) TO anon, authenticated, service_role;
