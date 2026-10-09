-- TP-2 reconciliation. Read-only diagnostics; never repairs data or stops dual-write.
-- Run with an approved read-only connection. Every result describes one snapshot.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '30s';

-- Event volumes and people are different units. Never add per-entity unique users.
SELECT source, event_type, entity_type, COUNT(*) AS rows, SUM(event_count) AS events,
       COUNT(DISTINCT user_id) AS users,
       SUM(event_count) FILTER (WHERE user_id IS NULL) AS anonymous_events,
       MIN(occurred_at) AS first_event, MAX(occurred_at) AS last_event
FROM public.engagement_events
WHERE event_type IN ('card_click', 'redirect')
GROUP BY source, event_type, entity_type ORDER BY 2, 3, 1;

-- Resolve only authoritative opportunity IDs. Do not infer mappings from names.
SELECT e.source, e.event_type, SUM(e.event_count) AS events,
       COUNT(*) FILTER (WHERE po.id IS NULL) AS unresolved_rows,
       COALESCE(SUM(e.event_count) FILTER (WHERE po.id IS NULL), 0) AS unresolved_events,
       COUNT(*) FILTER (WHERE po.id IS NOT NULL AND i.id IS NULL) AS missing_institution_rows
FROM public.engagement_events e
LEFT JOIN public.partner_opportunities po
  ON po.id::text = COALESCE(e.entity_id::text, regexp_replace(e.unified_opportunity_id, '^partner_', ''))
LEFT JOIN public.institutions i ON i.id = po.institution_id
WHERE e.entity_type = 'partner_opportunity' AND e.event_type IN ('card_click', 'redirect')
GROUP BY 1, 2 ORDER BY 1, 2;

-- Redirect parity includes the historical source and live writes exactly once.
-- Date buckets use UTC, independent of the operator session timezone.
WITH old AS (
 SELECT partner_id, (created_at AT TIME ZONE 'UTC')::date AS event_day,
        COUNT(*) AS events, COUNT(DISTINCT user_id) AS users
 FROM public.external_redirect_clicks GROUP BY 1, 2
), new AS (
 SELECT entity_id AS partner_id, (occurred_at AT TIME ZONE 'UTC')::date AS event_day,
        SUM(event_count) AS events, COUNT(DISTINCT user_id) AS users
 FROM public.engagement_events
 WHERE event_type = 'redirect' AND entity_type = 'partner_opportunity'
 GROUP BY 1, 2
)
SELECT COUNT(*) AS groups_compared,
       COUNT(*) FILTER (
         WHERE COALESCE(o.events, 0) <> COALESCE(n.events, 0)
            OR COALESCE(o.users, 0) <> COALESCE(n.users, 0)
       ) AS mismatched_entity_days
FROM old o FULL JOIN new n USING (partner_id, event_day);

-- Historical counters are snapshots, not one row per click. Preserve their original timestamp.
-- Current legacy counters are mutable; increments are not missing backfill.
WITH snapshot AS (
 SELECT user_id, entity_id, event_count, occurred_at
 FROM public.engagement_events WHERE source = 'legacy_partners_click_aggregate'
)
SELECT COUNT(*) AS snapshot_pairs, SUM(s.event_count) AS snapshot_events,
       COUNT(DISTINCT s.user_id) AS snapshot_users,
       COUNT(*) FILTER (WHERE pc.id IS NULL) AS missing_legacy_pairs,
       COUNT(*) FILTER (WHERE pc.clicks < s.event_count) AS counter_regressions,
       COUNT(*) FILTER (WHERE pc.created_at <> s.occurred_at) AS original_timestamp_mismatches,
       SUM(pc.clicks - s.event_count) AS increments_on_snapshot_pairs
FROM snapshot s LEFT JOIN public.partners_click pc
  ON (pc.user_id, pc.partner_id) = (s.user_id, s.entity_id);

-- The delivered producer deduplicates the new event per subject/entity/minute.
-- Legacy writes occur for both "created" and "duplicate"; anonymous writes are skipped.
-- An anonymous event later attached to a user still retains its original event_id.
-- Therefore all-time legacy counters and the expanded event population cannot be equated.
-- This categorization proves provenance, not the exact cause of each extra legacy increment.
WITH snapshot AS (
 SELECT user_id, entity_id, SUM(event_count)::bigint AS n
 FROM public.engagement_events WHERE source = 'legacy_partners_click_aggregate' GROUP BY 1, 2
), live AS (
 SELECT user_id, entity_id, SUM(event_count)::bigint AS n,
        COALESCE(SUM(event_count) FILTER (
          WHERE anonymous_id IS NOT NULL AND event_id LIKE 'card_click:' || anonymous_id || ':%'
        ), 0)::bigint AS originally_anonymous
 FROM public.engagement_events
 WHERE source = 'card' AND entity_type = 'partner_opportunity'
   AND event_type = 'card_click' AND user_id IS NOT NULL GROUP BY 1, 2
), old AS (
 SELECT user_id, partner_id, SUM(clicks)::bigint AS n FROM public.partners_click GROUP BY 1, 2
), pairs AS (
 SELECT COALESCE(o.n, 0) - COALESCE(s.n, 0) AS legacy_increment,
        COALESCE(l.n, 0) - COALESCE(l.originally_anonymous, 0) AS originally_authenticated,
        COALESCE(l.originally_anonymous, 0) AS attached_anonymous
 FROM old o FULL JOIN live l ON (o.user_id, o.partner_id) = (l.user_id, l.entity_id)
 LEFT JOIN snapshot s
   ON (s.user_id, s.entity_id) = (COALESCE(o.user_id, l.user_id), COALESCE(o.partner_id, l.entity_id))
)
SELECT CASE WHEN legacy_increment = originally_authenticated THEN 'equal'
            WHEN legacy_increment > originally_authenticated THEN 'legacy_greater'
            ELSE 'new_greater' END AS comparison,
       COUNT(*) AS pairs, SUM(legacy_increment) AS legacy_increment,
       SUM(originally_authenticated) AS originally_authenticated,
       SUM(attached_anonymous) AS attached_anonymous,
       SUM(originally_authenticated - legacy_increment) AS difference
FROM pairs GROUP BY 1 ORDER BY 1;

-- Source / entity / period export. Aggregated legacy counters have the original row's day:
-- their individual click times cannot be reconstructed from the legacy schema.
SELECT source, event_type, entity_type,
       COALESCE(entity_id::text, unified_opportunity_id) AS entity_key,
       (occurred_at AT TIME ZONE 'UTC')::date AS event_day,
       SUM(event_count) AS events, COUNT(DISTINCT user_id) AS users
FROM public.engagement_events
WHERE event_type IN ('card_click', 'redirect')
GROUP BY 1, 2, 3, 4, 5 ORDER BY 2, 3, 1, 4, 5;
-- Global unique-user conservation; do not sum source-specific distinct users.
WITH old AS (
 SELECT DISTINCT user_id FROM public.partners_click
), new AS (
 SELECT DISTINCT user_id FROM public.engagement_events
 WHERE event_type = 'card_click' AND entity_type = 'partner_opportunity' AND user_id IS NOT NULL
), anonymous_origin AS (
 SELECT DISTINCT user_id FROM public.engagement_events
 WHERE event_type = 'card_click' AND entity_type = 'partner_opportunity'
   AND anonymous_id IS NOT NULL AND event_id LIKE 'card_click:' || anonymous_id || ':%'
)
SELECT (SELECT COUNT(*) FROM old) AS legacy_users,
       (SELECT COUNT(*) FROM new) AS new_users,
       (SELECT COUNT(*) FROM old o WHERE NOT EXISTS (
         SELECT 1 FROM new n WHERE n.user_id = o.user_id
       )) AS legacy_only_users,
       (SELECT COUNT(*) FROM new n WHERE NOT EXISTS (
         SELECT 1 FROM old o WHERE o.user_id = n.user_id
       )) AS new_only_users,
       (SELECT COUNT(*) FROM new n JOIN anonymous_origin a USING (user_id)
        WHERE NOT EXISTS (SELECT 1 FROM old o WHERE o.user_id = n.user_id)
       ) AS new_only_users_with_anonymous_origin;
COMMIT;

