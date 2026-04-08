-- =============================================================================
-- Migration: add_opportunity_type_to_view — Sprint 02 Wave 4.1 (OPTIMIZED)
-- Otimização: Branch limits para acelerar o sorting da UNION ALL em datasets grandes.
-- Adiciona índices de performance para acelerar o sorting da view v_unified_opportunities.
-- =============================================================================

-- 1. Índices de performance (Garante que a ordenação seja indexada)
CREATE INDEX IF NOT EXISTS idx_opportunities_created_at_desc ON opportunities(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_partner_opportunities_created_at_desc ON partner_opportunities(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_partner_opportunities_status_approved ON partner_opportunities(status) WHERE status = 'approved';

DROP VIEW IF EXISTS v_unified_opportunities;

CREATE OR REPLACE VIEW v_unified_opportunities AS
  -- Branch MEC (Limitado a 500 para evitar full scans em joins pesados)
  (SELECT
    'mec_' || o.id::text               AS unified_id,
    c.course_name                       AS title,
    i.name                              AS provider_name,
    o.opportunity_type                  AS type,
    o.opportunity_type                  AS opportunity_type,
    CASE
      WHEN o.opportunity_type = 'sisu'   THEN 'public_universities'
      WHEN o.opportunity_type = 'prouni' THEN 'grants_scholarships'
      ELSE 'educational_programs'
    END                                 AS category,
    false                               AS is_partner,
    cp.city || ', ' || cp.state        AS location,
    jsonb_build_array(
      CASE WHEN o.opportunity_type = 'prouni' THEN '100% Gratuito' END,
      o.shift
    ) - 'null'                          AS badges,
    o.created_at                        AS created_at,
    NULL::text                          AS external_redirect_url,
    false                               AS external_redirect_enabled
  FROM opportunities o
  JOIN courses c  ON c.id  = o.course_id
  JOIN campus  cp ON cp.id = c.campus_id
  JOIN institutions i ON i.id = cp.institution_id
  WHERE o.semester = '1'
    AND (
      (o.opportunity_type = 'sisu'   AND o.year = 2026) OR
      (o.opportunity_type = 'prouni' AND o.year = 2025)
    )
  ORDER BY o.created_at DESC
  LIMIT 500)

  UNION ALL

  -- Branch Parceiro
  (SELECT
    'partner_' || po.id::text                                          AS unified_id,
    po.name                                                             AS title,
    i.name                                                              AS provider_name,
    'partner'                                                           AS type,
    po.opportunity_type                                                 AS opportunity_type,
    'educational_programs'                                              AS category,
    true                                                                AS is_partner,
    'Nacional'                                                          AS location,
    COALESCE(po.eligibility_criteria->'badges', '[]'::jsonb)           AS badges,
    po.created_at                                                       AS created_at,
    po.external_redirect_config->>'url'                                 AS external_redirect_url,
    COALESCE(
      (po.external_redirect_config->>'enabled')::boolean,
      false
    )                                                                   AS external_redirect_enabled
  FROM partner_opportunities po
  JOIN institutions i ON i.id = po.institution_id
  WHERE po.status = 'approved'
  ORDER BY po.created_at DESC
  LIMIT 500);

ANALYZE opportunities;
ANALYZE partner_opportunities;
