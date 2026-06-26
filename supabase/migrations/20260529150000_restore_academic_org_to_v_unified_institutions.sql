-- Migration: Restore academic_organization and administrative_category to v_unified_institutions
-- Hotfix Sprint 15.0 (NUB-RD-9)
-- 
-- Context: Migration 20260528100100_add_website_url_to_partner_institutions.sql
-- recreated v_unified_institutions without academic_organization and
-- administrative_category columns. The frontend (institutions.ts lines 80 & 128)
-- still SELECTs these columns, causing a 500 error on the /instituicoes page.
--
-- Pattern: COALESCE(sisu.academic_organization, ie.academic_organization) follows
-- the established convention from 20260513143500_add_categories_to_v_unified_institutions.sql
-- to cover institutions present in either institutionsinfosisu or institutionsinfoemec.

DROP VIEW IF EXISTS v_unified_institutions CASCADE;

CREATE OR REPLACE VIEW v_unified_institutions AS
SELECT
    i.id,
    i.name,
    COALESCE(
        pi.location,
        CASE
            WHEN ie.city IS NOT NULL AND ie.state IS NOT NULL THEN ie.city || ' - ' || ie.state
            WHEN ie.city IS NOT NULL THEN ie.city
            WHEN ie.state IS NOT NULL THEN ie.state
            ELSE (
                SELECT c.city || ' - ' || c.state
                FROM campus c
                WHERE c.institution_id = i.id AND c.city IS NOT NULL
                LIMIT 1
            )
        END
    ) AS location,
    pi.logo_url,
    pi.cover_url,
    pi.brand_color,
    pi.description,
    pi.website_url,
    sisu.acronym,
    COALESCE(sisu.academic_organization, ie.academic_organization) AS academic_organization,
    COALESCE(sisu.administrative_category, ie.administrative_category) AS administrative_category,
    CASE
        WHEN i.is_partner IS TRUE THEN 'partner'::text
        ELSE 'mec'::text
    END AS type,
    -- opp_types intentionally NULL: CTE-based computation was removed in 20260528100100
    -- to avoid timeouts. This is not a regression of this hotfix.
    NULL::text[] AS opp_types
FROM institutions i
LEFT JOIN partner_institutions pi ON pi.institution_id = i.id
LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
LEFT JOIN institutionsinfosisu sisu ON sisu.institution_id = i.id;

GRANT SELECT ON v_unified_institutions TO anon, authenticated, service_role;
