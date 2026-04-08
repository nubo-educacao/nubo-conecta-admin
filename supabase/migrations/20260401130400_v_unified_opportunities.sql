-- =============================================================================
-- Migration: v_unified_opportunities — Sprint 02 Wave 1.5
-- View unificada que expõe oportunidades MEC (sisu/prouni) e parceiras num
-- único contrato harmonizado. Dependência: partner_opportunities (migration 003)
-- deve existir antes desta migration ser aplicada.
-- Circuit Breaker: revisar antes de qualquer `supabase db push`.
-- =============================================================================

CREATE OR REPLACE VIEW v_unified_opportunities AS
  -- Branch MEC: oportunidades Sisu 2026 e Prouni 2025 semestre 1
  SELECT
    'mec_' || o.id::text               AS unified_id,
    c.course_name                       AS title,
    i.name                              AS provider_name,
    o.opportunity_type                  AS type,
    CASE
      WHEN o.opportunity_type = 'sisu'   THEN 'public_universities'
      WHEN o.opportunity_type = 'prouni' THEN 'grants_scholarships'
      ELSE 'educational_programs'
    END                                 AS category,
    false                               AS is_partner,
    cp.city || ', ' || cp.state        AS location,
    -- Remove null elements from badges array via '-' operator
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

  UNION ALL

  -- Branch Parceiro: oportunidades com status 'approved' das instituições parceiras
  SELECT
    'partner_' || po.id::text                                          AS unified_id,
    po.name                                                             AS title,
    i.name                                                              AS provider_name,
    'partner'                                                           AS type,
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
  WHERE po.status = 'approved';
