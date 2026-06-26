-- Migration: update_v_unified_institutions_opp_types_order
-- Sprint 8.0: Atualizar view para retornar opportunity_type ordernado por frequência.

DROP VIEW IF EXISTS v_unified_institutions;

CREATE OR REPLACE VIEW v_unified_institutions AS
WITH opp_counts AS (
    SELECT 
        c.institution_id,
        o.opportunity_type,
        COUNT(*) as freq
    FROM campus c
    JOIN courses co ON co.campus_id = c.id
    JOIN opportunities o ON o.course_id = co.id
    WHERE o.opportunity_type IS NOT NULL
    GROUP BY c.institution_id, o.opportunity_type
),
inst_opps AS (
    SELECT 
        institution_id,
        ARRAY_AGG(opportunity_type ORDER BY freq DESC) as opp_types
    FROM opp_counts
    GROUP BY institution_id
)
SELECT 
    i.id,
    i.name,
    COALESCE(
        pi.location,
        CASE 
            WHEN ie.city IS NOT NULL AND ie.state IS NOT NULL THEN ie.city || ' - ' || ie.state
            WHEN ie.city IS NOT NULL THEN ie.city
            WHEN ie.state IS NOT NULL THEN ie.state
            ELSE (SELECT c.city || ' - ' || c.state FROM campus c WHERE c.institution_id = i.id AND c.city IS NOT NULL LIMIT 1)
        END
    ) as location,
    pi.logo_url,
    pi.cover_url,
    pi.brand_color,
    pi.description,
    CASE WHEN i.is_partner IS TRUE THEN 'partner' ELSE 'mec' END as type,
    io.opp_types
FROM institutions i
LEFT JOIN partner_institutions pi ON pi.institution_id = i.id
LEFT JOIN institutionsinfoemec ie ON ie.institution_id = i.id
LEFT JOIN inst_opps io ON io.institution_id = i.id;
