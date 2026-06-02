-- =============================================================================
-- Migration: v_unified_institutions — Sprint 8.0
-- View unificada que expõe parceiras e instituições MEC num contrato único.
-- Usado por /instituicoes (listagem) e /instituicoes/[id] (detalhe).
-- =============================================================================

CREATE OR REPLACE VIEW v_unified_institutions AS
  -- Branch parceira: JOIN com partner_institutions para branding
  SELECT
    i.id,
    i.name,
    pi.location,
    pi.logo_url,
    pi.cover_url,
    pi.brand_color,
    pi.description,
    'partner'::text AS type
  FROM institutions i
  JOIN partner_institutions pi ON pi.institution_id = i.id
  WHERE i.is_partner = true

UNION ALL

  -- Branch MEC: instituições sem parceria, sem branding
  SELECT
    i.id,
    i.name,
    NULL::text AS location,
    NULL::text AS logo_url,
    NULL::text AS cover_url,
    NULL::text AS brand_color,
    NULL::text AS description,
    'mec'::text AS type
  FROM institutions i
  WHERE i.is_partner IS DISTINCT FROM true;

GRANT SELECT ON v_unified_institutions TO anon, authenticated, service_role;
