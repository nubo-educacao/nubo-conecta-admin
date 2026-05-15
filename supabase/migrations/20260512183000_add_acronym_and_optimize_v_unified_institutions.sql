-- Update v_unified_institutions: Add acronym and optimize for performance
-- Sprint 8.0: Search by name, acronym and location

DROP VIEW IF EXISTS v_unified_institutions CASCADE;

CREATE VIEW v_unified_institutions AS
 WITH all_opps AS (
         SELECT c.institution_id,
            o.opportunity_type
           FROM ((campus c
             JOIN courses co ON ((co.campus_id = c.id)))
             JOIN opportunities o ON ((o.course_id = co.id)))
          WHERE (o.opportunity_type IS NOT NULL)
        UNION ALL
         SELECT po.institution_id,
            po.opportunity_type
           FROM partner_opportunities po
          WHERE (po.opportunity_type IS NOT NULL)
        ), opp_counts AS (
         SELECT all_opps.institution_id,
            all_opps.opportunity_type,
            count(*) AS freq
           FROM all_opps
          GROUP BY all_opps.institution_id, all_opps.opportunity_type
        ), inst_opps AS (
         SELECT opp_counts.institution_id,
            array_agg(opp_counts.opportunity_type ORDER BY opp_counts.freq DESC) AS opp_types
           FROM opp_counts
          GROUP BY opp_counts.institution_id
        )
 SELECT i.id,
    i.name,
    COALESCE(pi.location,
        CASE
            WHEN ((ie.city IS NOT NULL) AND (ie.state IS NOT NULL)) THEN ((ie.city || ' - '::text) || ie.state)
            WHEN (ie.city IS NOT NULL) THEN ie.city
            WHEN (ie.state IS NOT NULL) THEN ie.state
            ELSE ( SELECT ((c.city || ' - '::text) || c.state)
               FROM campus c
              WHERE ((c.institution_id = i.id) AND (c.city IS NOT NULL))
             LIMIT 1)
        END) AS location,
    pi.logo_url,
    pi.cover_url,
    pi.brand_color,
    pi.description,
    sisu.acronym,
        CASE
            WHEN (i.is_partner IS TRUE) THEN 'partner'::text
            ELSE 'mec'::text
        END AS type,
    io.opp_types
   FROM ((((institutions i
     LEFT JOIN partner_institutions pi ON ((pi.institution_id = i.id)))
     LEFT JOIN institutionsinfoemec ie ON ((ie.institution_id = i.id)))
     LEFT JOIN institutionsinfosisu sisu ON ((sisu.institution_id = i.id)))
     LEFT JOIN inst_opps io ON ((io.institution_id = i.id)));
