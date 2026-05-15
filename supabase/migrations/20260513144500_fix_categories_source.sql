-- Migration: Fix academic_organization and administrative_category source to prioritize sisu
-- Sprint 8.0

CREATE OR REPLACE VIEW v_unified_institutions AS
WITH inst_opps AS (
  SELECT institution_id, array_agg(DISTINCT opportunity_type) as opp_types
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
