-- =============================================================================
-- Migration: Fase 4 — Reconstruir v_unified_opportunities com 3 branches
-- ADR Data-Layer Audit v2: 2 branches MEC unificado → 3 branches (SisU + ProUni + Partner)
-- Cada branch faz JOIN direto na sua tabela de vacancies normalizada.
-- Sprint 8.0
-- =============================================================================

-- v_unified_institutions depende da matview; dropar em cascade e recriar ambas
DROP VIEW IF EXISTS v_unified_institutions;
DROP MATERIALIZED VIEW IF EXISTS v_unified_opportunities CASCADE;

CREATE MATERIALIZED VIEW v_unified_opportunities AS

  -- ═══ Branch 1: SisU ═══
  SELECT * FROM (
    SELECT DISTINCT ON (c.id)
      'mec_' || c.id::text               AS unified_id,
      c.course_name                       AS title,
      i.name                              AS provider_name,
      'sisu'::text                        AS type,
      'sisu'::text                        AS opportunity_type,
      'public_universities'::text         AS category,
      false                               AS is_partner,
      cp.city || ', ' || cp.state         AS location,
      jsonb_build_array(o.shift) - 'null' AS badges,
      o.created_at,
      NULL::text                          AS external_redirect_url,
      false                               AS external_redirect_enabled,
      'approved'::text                    AS status,
      id_dates.start_date                 AS starts_at,
      id_dates.end_date                   AS ends_at,
      NULL::numeric                       AS match_score,
      s.min_cutoff                        AS min_cutoff_score,
      s.max_cutoff                        AS max_cutoff_score,
      NULL::text                          AS institution_cover_url,
      sv.nu_vagas_autorizadas,
      sv.qt_vagas_ofertadas,
      sv.qt_inscricao_2025,
      sv.vagas_ociosas_2025,
      i.id                                AS institution_id,
      ie.igc                              AS institution_igc,
      ie.academic_organization            AS institution_organization,
      ie.administrative_category          AS institution_category,
      ie.site                             AS institution_site,
      NULL::jsonb                         AS eligibility_criteria,
      NULL::jsonb                         AS benefits,
      NULL::text                          AS brand_color,
      jsonb_build_object(
        'redacao',    sv.peso_redacao,
        'matematica', sv.peso_matematica,
        'linguagens', sv.peso_linguagens,
        'humanas',    sv.peso_ciencias_humanas,
        'natureza',   sv.peso_ciencias_natureza
      )                                   AS weights
    FROM opportunities o
    JOIN courses c   ON c.id   = o.course_id
    JOIN campus  cp  ON cp.id  = c.campus_id
    JOIN institutions i ON i.id = cp.institution_id
    LEFT JOIN (
      SELECT course_id, MIN(cutoff_score) AS min_cutoff, MAX(cutoff_score) AS max_cutoff
      FROM opportunities WHERE opportunity_type = 'sisu' GROUP BY course_id
    ) s ON s.course_id = o.course_id
    LEFT JOIN LATERAL (
      SELECT d.start_date, d.end_date FROM important_dates d
      WHERE d.type = 'sisu' AND d.controls_opportunity_dates = true
      ORDER BY d.start_date DESC LIMIT 1
    ) id_dates ON true
    LEFT JOIN opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
    LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
    WHERE o.semester = '1' AND o.opportunity_type = 'sisu' AND o.year = 2026
    ORDER BY c.id, o.created_at
  ) sisu_branch

  UNION ALL

  -- ═══ Branch 2: ProUni ═══
  SELECT * FROM (
    SELECT DISTINCT ON (c.id)
      'mec_' || c.id::text               AS unified_id,
      c.course_name                       AS title,
      i.name                              AS provider_name,
      'prouni'::text                      AS type,
      'prouni'::text                      AS opportunity_type,
      'grants_scholarships'::text         AS category,
      false                               AS is_partner,
      cp.city || ', ' || cp.state         AS location,
      jsonb_build_array('100% Gratuito', o.shift) - 'null' AS badges,
      o.created_at,
      NULL::text                          AS external_redirect_url,
      false                               AS external_redirect_enabled,
      'approved'::text                    AS status,
      id_dates.start_date                 AS starts_at,
      id_dates.end_date                   AS ends_at,
      NULL::numeric                       AS match_score,
      s.min_cutoff                        AS min_cutoff_score,
      s.max_cutoff                        AS max_cutoff_score,
      NULL::text                          AS institution_cover_url,
      -- ProUni não tem vagas SisU; agregado da tabela normalizada
      NULL::text                          AS nu_vagas_autorizadas,
      pv_agg.qt_vagas_ofertadas,
      NULL::text                          AS qt_inscricao_2025,
      pv_agg.vagas_ociosas_2025,
      i.id                                AS institution_id,
      ie.igc                              AS institution_igc,
      ie.academic_organization            AS institution_organization,
      ie.administrative_category          AS institution_category,
      ie.site                             AS institution_site,
      NULL::jsonb                         AS eligibility_criteria,
      NULL::jsonb                         AS benefits,
      NULL::text                          AS brand_color,
      NULL::jsonb                         AS weights
    FROM opportunities o
    JOIN courses c   ON c.id   = o.course_id
    JOIN campus  cp  ON cp.id  = c.campus_id
    JOIN institutions i ON i.id = cp.institution_id
    LEFT JOIN (
      SELECT course_id, MIN(cutoff_score) AS min_cutoff, MAX(cutoff_score) AS max_cutoff
      FROM opportunities WHERE opportunity_type = 'prouni' GROUP BY course_id
    ) s ON s.course_id = o.course_id
    LEFT JOIN LATERAL (
      SELECT d.start_date, d.end_date FROM important_dates d
      WHERE d.type = 'prouni' AND d.controls_opportunity_dates = true
      ORDER BY d.start_date DESC LIMIT 1
    ) id_dates ON true
    LEFT JOIN LATERAL (
      SELECT
        SUM(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
        SUM(
          (pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) -
          (pv.bolsas_ampla_ocupada  + pv.bolsas_cota_ocupada)
        )::integer AS vagas_ociosas_2025
      FROM opportunities_prouni_vacancies pv
      WHERE pv.opportunity_id = o.id
    ) pv_agg ON true
    LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
    WHERE o.semester = '1' AND o.opportunity_type = 'prouni' AND o.year = 2025
    ORDER BY c.id, o.created_at
  ) prouni_branch

  UNION ALL

  -- ═══ Branch 3: Partner ═══
  SELECT
    'partner_' || po.id::text           AS unified_id,
    po.name                             AS title,
    i.name                              AS provider_name,
    'partner'::text                     AS type,
    po.opportunity_type                 AS opportunity_type,
    'educational_programs'::text        AS category,
    true                                AS is_partner,
    'Nacional'::text                    AS location,
    COALESCE(po.eligibility_criteria->'badges', '[]'::jsonb) AS badges,
    po.created_at,
    po.external_redirect_config->>'url' AS external_redirect_url,
    COALESCE((po.external_redirect_config->>'enabled')::boolean, false) AS external_redirect_enabled,
    po.status::text                     AS status,
    po.starts_at,
    po.ends_at,
    NULL::numeric                       AS match_score,
    NULL::numeric                       AS min_cutoff_score,
    NULL::numeric                       AS max_cutoff_score,
    pi.cover_url                        AS institution_cover_url,
    NULL::text                          AS nu_vagas_autorizadas,
    NULL::text                          AS qt_vagas_ofertadas,
    NULL::text                          AS qt_inscricao_2025,
    NULL::integer                       AS vagas_ociosas_2025,
    i.id                                AS institution_id,
    ie.igc                              AS institution_igc,
    ie.academic_organization            AS institution_organization,
    ie.administrative_category          AS institution_category,
    ie.site                             AS institution_site,
    po.eligibility_criteria,
    NULL::jsonb                         AS benefits,
    pi.brand_color,
    NULL::jsonb                         AS weights
  FROM partner_opportunities po
  JOIN institutions i ON i.id = po.institution_id
  LEFT JOIN partner_institutions pi ON pi.institution_id = i.id
  LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
  WHERE po.status = 'approved';

-- Índices
CREATE UNIQUE INDEX IF NOT EXISTS idx_v_unified_opportunities_id ON v_unified_opportunities (unified_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_institution ON v_unified_opportunities (institution_id);
CREATE INDEX IF NOT EXISTS idx_v_unified_opportunities_type ON v_unified_opportunities (type);

GRANT SELECT ON v_unified_opportunities TO anon, authenticated, service_role;

-- Recriar v_unified_institutions (foi dropada em cascade acima)
CREATE OR REPLACE VIEW v_unified_institutions AS
WITH inst_opps AS (
  SELECT institution_id, array_agg(DISTINCT opportunity_type) AS opp_types
  FROM v_unified_opportunities
  GROUP BY institution_id
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
