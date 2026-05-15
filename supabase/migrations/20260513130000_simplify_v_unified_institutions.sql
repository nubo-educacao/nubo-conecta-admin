-- Simplify v_unified_institutions: Remove heavy opp_types CTE that caused timeouts.
-- The CTE was joining campus → courses → opportunities for ALL institutions
-- before applying any LIMIT, causing full-table scans on every paginated request.
-- opp_types is not used in search/listing logic; can be added back via a lazy
-- subquery on the detail page if ever needed.

DROP VIEW IF EXISTS v_unified_institutions CASCADE;

CREATE VIEW v_unified_institutions AS
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

-- Index hints for search performance (name, acronym, location via EMEC)
-- If not already present:
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_institutions_name ON institutions (name);
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_institutionsinfosisu_acronym ON institutionsinfosisu (acronym);
