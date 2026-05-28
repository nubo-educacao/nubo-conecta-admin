-- Migration: ADD COLUMN website_url TEXT em partner_institutions
-- and update v_unified_institutions view to include it.

ALTER TABLE public.partner_institutions
  ADD COLUMN IF NOT EXISTS website_url TEXT;

COMMENT ON COLUMN public.partner_institutions.website_url IS
  'URL of the partner institution website.';

-- Drop existing view first due to column changes
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
    CASE
        WHEN i.is_partner IS TRUE THEN 'partner'::text
        ELSE 'mec'::text
    END AS type,
    NULL::text[] AS opp_types
FROM institutions i
LEFT JOIN partner_institutions pi ON pi.institution_id = i.id
LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
LEFT JOIN institutionsinfosisu sisu ON sisu.institution_id = i.id;

GRANT SELECT ON v_unified_institutions TO anon, authenticated, service_role;
