-- Migration: Deep Details Enrichment for v_unified_opportunities
-- Adds vacancies, weights, and institutional metadata
-- Sprint 7.0 - Deep Detail Pages

DROP MATERIALIZED VIEW IF EXISTS v_unified_opportunities;

CREATE MATERIALIZED VIEW v_unified_opportunities AS
  -- Branch MEC: Sisu e Prouni
  SELECT
    'mec_' || o.id::text               AS unified_id,
    c.course_name                       AS title,
    i.name                              AS provider_name,
    o.opportunity_type                  AS type,           -- sisu | prouni
    o.opportunity_type                  AS opportunity_type, -- sisu | prouni (subtype)
    CASE
      WHEN o.opportunity_type = 'sisu'   THEN 'public_universities'
      WHEN o.opportunity_type = 'prouni' THEN 'grants_scholarships'
      ELSE 'educational_programs'
    END                                 AS category,
    false                               AS is_partner,
    cp.city || ', ' || cp.state        AS location,
    jsonb_build_array(CASE WHEN o.opportunity_type = 'prouni' THEN '100% Gratuito' END, o.shift) - 'null' AS badges,
    o.created_at                        AS created_at,
    NULL::text                          AS external_redirect_url,
    false                               AS external_redirect_enabled,
    'approved'::text                    AS status,
    id_dates.start_date                 AS starts_at,
    id_dates.end_date                   AS ends_at,
    NULL::numeric                       AS match_score,
    s.min_cutoff                        AS min_cutoff_score,
    s.max_cutoff                        AS max_cutoff_score,
    NULL::text                          AS institution_cover_url,
    -- New MEC Detail Fields
    sv.nu_vagas_autorizadas,
    sv.qt_vagas_ofertadas,
    sv.qt_inscricao_2025,
    sv.vagas_ociosas_2025,
    -- Institution Details
    ie.igc                             AS institution_igc,
    ie.academic_organization           AS institution_organization,
    ie.administrative_category         AS institution_category,
    ie.site                            AS institution_site,
    -- Partner placeholders
    NULL::jsonb                         AS eligibility_criteria,
    NULL::jsonb                         AS benefits,
    NULL::text                          AS brand_color,
    -- Weights (as JSONB for unified storage if needed, or separate columns)
    jsonb_build_object(
      'redacao', sv.peso_redacao,
      'matematica', sv.peso_matematica,
      'linguagens', sv.peso_linguagens,
      'humanas', sv.peso_ciencias_humanas,
      'natureza', sv.peso_ciencias_natureza
    )                                   AS weights
  FROM opportunities o
  JOIN courses c  ON c.id  = o.course_id
  JOIN campus  cp ON cp.id = c.campus_id
  JOIN institutions i ON i.id = cp.institution_id
  LEFT JOIN (SELECT course_id, MIN(cutoff_score) as min_cutoff, MAX(cutoff_score) as max_cutoff FROM opportunities GROUP BY course_id) s ON s.course_id = o.course_id
  LEFT JOIN LATERAL (SELECT d.start_date, d.end_date FROM important_dates d WHERE d.type = o.opportunity_type AND d.controls_opportunity_dates = true ORDER BY d.start_date DESC LIMIT 1) id_dates ON true
  LEFT JOIN opportunitiessisuvacancies sv ON sv.opportunity_id = o.id
  LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
  WHERE o.semester = '1' AND ((o.opportunity_type = 'sisu' AND o.year = 2026) OR (o.opportunity_type = 'prouni' AND o.year = 2025))

  UNION ALL

  -- Branch Parceiro: com subtipo (Bolsa, Mentoria, etc)
  SELECT
    'partner_' || po.id::text           AS unified_id,
    po.name                              AS title,
    i.name                               AS provider_name,
    'partner'                            AS type,
    po.opportunity_type                  AS opportunity_type, -- bolsa | mentoria | etc
    'educational_programs'               AS category,
    true                                 AS is_partner,
    'Nacional'                           AS location,
    COALESCE(po.eligibility_criteria->'badges', '[]'::jsonb) AS badges,
    po.created_at                        AS created_at,
    po.external_redirect_config->>'url'  AS external_redirect_url,
    COALESCE((po.external_redirect_config->>'enabled')::boolean, false) AS external_redirect_enabled,
    po.status::text                      AS status,
    po.starts_at                         AS starts_at,
    po.ends_at                           AS ends_at,
    NULL::numeric                        AS match_score,
    NULL::numeric                        AS min_cutoff_score,
    NULL::numeric                        AS max_cutoff_score,
    pi.cover_url                         AS institution_cover_url,
    -- Partner specific details
    NULL::text                           AS nu_vagas_autorizadas,
    NULL::text                           AS qt_vagas_ofertadas,
    NULL::text                           AS qt_inscricao_2025,
    NULL::integer                        AS vagas_ociosas_2025,
    -- Institution Details (if available for partners)
    ie.igc                             AS institution_igc,
    ie.academic_organization           AS institution_organization,
    ie.administrative_category         AS institution_category,
    ie.site                            AS institution_site,
    -- Partner Fields
    po.eligibility_criteria,
    NULL::jsonb                          AS benefits,
    pi.brand_color,
    -- Weights (not applicable for partners)
    NULL::jsonb                          AS weights
  FROM partner_opportunities po
  JOIN institutions i ON i.id = po.institution_id
  LEFT JOIN partner_institutions pi ON pi.institution_id = i.id
  LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
  WHERE po.status = 'approved';

-- Índices para performance
CREATE UNIQUE INDEX IF NOT EXISTS idx_v_unified_opportunities_id ON v_unified_opportunities (unified_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_type ON v_unified_opportunities (type);

-- Permissões
GRANT SELECT ON v_unified_opportunities TO anon, authenticated, service_role;
