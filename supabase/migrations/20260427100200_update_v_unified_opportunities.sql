-- =============================================================================
-- Migration: Sprint 6 — View v_unified_opportunities com status + datas
-- Adiciona status, starts_at, ends_at a ambos os branches (MEC + Parceiro).
-- MEC: datas derivadas de important_dates via controls_opportunity_dates flag.
-- Parceiro: datas diretas de partner_opportunities.
-- =============================================================================

DROP VIEW IF EXISTS v_unified_opportunities;
CREATE VIEW v_unified_opportunities AS
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
    jsonb_build_array(
      CASE WHEN o.opportunity_type = 'prouni' THEN '100% Gratuito' END,
      o.shift
    ) - 'null'                          AS badges,
    o.created_at                        AS created_at,
    NULL::text                          AS external_redirect_url,
    false                               AS external_redirect_enabled,
    'approved'::text                    AS status,
    id_dates.start_date                 AS starts_at,
    id_dates.end_date                   AS ends_at
  FROM opportunities o
  JOIN courses c  ON c.id  = o.course_id
  JOIN campus  cp ON cp.id = c.campus_id
  JOIN institutions i ON i.id = cp.institution_id
  LEFT JOIN LATERAL (
    SELECT d.start_date, d.end_date
    FROM important_dates d
    WHERE d.type = o.opportunity_type
      AND d.controls_opportunity_dates = true
    ORDER BY d.start_date DESC
    LIMIT 1
  ) id_dates ON true
  WHERE o.semester = '1'
    AND (
      (o.opportunity_type = 'sisu'   AND o.year = 2026) OR
      (o.opportunity_type = 'prouni' AND o.year = 2025)
    )

  UNION ALL

  -- Branch Parceiro: oportunidades com status 'approved' das instituicoes parceiras
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
    )                                                                   AS external_redirect_enabled,
    po.status::text                                                     AS status,
    po.starts_at                                                        AS starts_at,
    po.ends_at                                                          AS ends_at
  FROM partner_opportunities po
  JOIN institutions i ON i.id = po.institution_id
  WHERE po.status = 'approved';
