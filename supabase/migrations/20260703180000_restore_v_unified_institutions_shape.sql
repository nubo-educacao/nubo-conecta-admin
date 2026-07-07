-- 20260703180000_restore_v_unified_institutions_shape.sql
-- Migration 20260703120000 recreated v_unified_institutions with a REGRESSED shape
-- (external_code / opportunity_types / categories) instead of the enriched shape the
-- apps were built against (20260612200000): location, logo_url, description, type
-- ('partner'/'mec'), opp_types, igc, ci, ci_ead, legal_nature, maintainer_name, etc.
--
-- The student app (getUnifiedInstitutions) and the Cloudinha catalog tool both query
-- these columns, so the regressed shape broke them:
--   "column v_unified_institutions.location does not exist".
--
-- Restore the enriched definition verbatim from 20260612200000. Plain VIEW — no refresh
-- needed; it reads live from v_unified_opportunities (matview) + EMEC/partner tables.
-- CREATE OR REPLACE cannot change a view's column set, so DROP + CREATE.

DROP VIEW IF EXISTS public.v_unified_institutions;

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
  -- EMEC specific details (MEC only)
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
