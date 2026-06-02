-- =============================================================================
-- Migration: Adicionar latitude e longitude na v_unified_opportunities
-- e criar a RPC de busca por distancia
-- =============================================================================

DROP VIEW IF EXISTS v_unified_institutions;
DROP MATERIALIZED VIEW IF EXISTS v_unified_opportunities CASCADE;

CREATE MATERIALIZED VIEW v_unified_opportunities AS
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
    sisu_branch.qt_inscricao_2025,
    sisu_branch.vagas_ociosas_2025,
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
            sv.qt_inscricao_2025,
            sv.vagas_ociosas_2025,
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
           FROM opportunities o
             JOIN courses c ON c.id = o.course_id
             JOIN campus cp ON cp.id = c.campus_id
             JOIN institutions i ON i.id = cp.institution_id
             LEFT JOIN ( SELECT opportunities.course_id,
                    min(opportunities.cutoff_score) AS min_cutoff,
                    max(opportunities.cutoff_score) AS max_cutoff
                   FROM opportunities
                  WHERE opportunities.opportunity_type = 'sisu'::text
                  GROUP BY opportunities.course_id) s ON s.course_id = o.course_id
             LEFT JOIN LATERAL ( SELECT d.start_date,
                    d.end_date
                   FROM important_dates d
                  WHERE d.type = 'sisu'::text AND d.controls_opportunity_dates = true
                  ORDER BY d.start_date DESC
                 LIMIT 1) id_dates ON true
             LEFT JOIN opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
             LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
             LEFT JOIN institutionsinfosisu sis ON sis.institution_id = i.id
          WHERE o.semester = '1'::text AND o.opportunity_type = 'sisu'::text AND o.year = 2026
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
    prouni_branch.qt_inscricao_2025,
    prouni_branch.vagas_ociosas_2025,
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
            NULL::text AS qt_inscricao_2025,
            pv_agg.vagas_ociosas_2025,
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
           FROM opportunities o
             JOIN courses c ON c.id = o.course_id
             JOIN campus cp ON cp.id = c.campus_id
             JOIN institutions i ON i.id = cp.institution_id
             LEFT JOIN ( SELECT opportunities.course_id,
                    min(opportunities.cutoff_score) AS min_cutoff,
                    max(opportunities.cutoff_score) AS max_cutoff
                   FROM opportunities
                  WHERE opportunities.opportunity_type = 'prouni'::text
                  GROUP BY opportunities.course_id) s ON s.course_id = o.course_id
             LEFT JOIN LATERAL ( SELECT d.start_date,
                    d.end_date
                   FROM important_dates d
                  WHERE d.type = 'prouni'::text AND d.controls_opportunity_dates = true
                  ORDER BY d.start_date DESC
                 LIMIT 1) id_dates ON true
             LEFT JOIN LATERAL ( SELECT sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
                    sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada))::integer AS vagas_ociosas_2025
                   FROM opportunities_prouni_vacancies pv
                  WHERE pv.opportunity_id = o.id) pv_agg ON true
             LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
             LEFT JOIN institutionsinfosisu sis ON sis.institution_id = i.id
          WHERE o.semester = '1'::text AND o.opportunity_type = 'prouni'::text AND o.year = 2025
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
    NULL::text AS qt_inscricao_2025,
    NULL::integer AS vagas_ociosas_2025,
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
   FROM partner_opportunities po
     JOIN institutions i ON i.id = po.institution_id
     LEFT JOIN partner_institutions pi ON pi.institution_id = i.id
     LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
     LEFT JOIN institutionsinfosisu sis ON sis.institution_id = i.id
  WHERE po.status::text IN ('incoming'::text, 'opened'::text, 'closed'::text);

-- Índices
CREATE UNIQUE INDEX IF NOT EXISTS idx_v_unified_opportunities_id ON v_unified_opportunities (unified_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_institution ON v_unified_opportunities (institution_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_type ON v_unified_opportunities (type);

GRANT SELECT ON v_unified_opportunities TO anon, authenticated, service_role;

-- Recreate v_unified_institutions (regular view that depends on v_unified_opportunities)
CREATE OR REPLACE VIEW v_unified_institutions AS
 WITH inst_opps AS (
         SELECT v_unified_opportunities.institution_id,
            array_agg(DISTINCT v_unified_opportunities.opportunity_type) AS opp_types
           FROM v_unified_opportunities
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
               FROM campus c
              WHERE c.institution_id = i.id AND c.city IS NOT NULL
             LIMIT 1)
        END) AS location,
    pi.logo_url,
    pi.cover_url,
    pi.brand_color,
    pi.description,
    sisu.acronym,
        CASE
            WHEN i.is_partner IS TRUE THEN 'partner'::text
            ELSE 'mec'::text
        END AS type,
    io.opp_types,
    COALESCE(sisu.academic_organization, ie.academic_organization) AS academic_organization,
    COALESCE(sisu.administrative_category, ie.administrative_category) AS administrative_category
   FROM institutions i
     LEFT JOIN partner_institutions pi ON pi.institution_id = i.id
     LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
     LEFT JOIN institutionsinfosisu sisu ON sisu.institution_id = i.id
     LEFT JOIN inst_opps io ON io.institution_id = i.id;

GRANT SELECT ON v_unified_institutions TO anon, authenticated, service_role;

-- Nova RPC para retornar as oportunidades unificadas com a distancia dinamicamente calculada
CREATE OR REPLACE FUNCTION get_unified_opportunities_by_distance(
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
    qt_inscricao_2025 TEXT,
    vagas_ociosas_2025 INTEGER,
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
    v.*,
    -- Calcula a distancia. Se a oportunidade for de parceiro (lat/long nulos) ou os parametros forem nulos, retorna 0
    CASE 
      WHEN v.latitude IS NULL OR v.longitude IS NULL THEN 0
      WHEN p_lat IS NULL OR p_long IS NULL THEN 0
      ELSE public.haversine_km(p_lat, p_long, v.latitude, v.longitude)
    END AS distance_km
  FROM public.v_unified_opportunities v
$$;
