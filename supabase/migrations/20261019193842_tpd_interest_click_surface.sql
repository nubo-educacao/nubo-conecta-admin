DROP FUNCTION IF EXISTS public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean);
-- D-l only: preserve exact published signature, guard and units.
CREATE OR REPLACE FUNCTION public.get_command_center_opportunity_interest(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 10, p_filter_campaign_id uuid DEFAULT NULL::uuid, p_filter_channel_id uuid DEFAULT NULL::uuid, p_filter_unattributed boolean DEFAULT NULL::boolean)
 RETURNS TABLE(opportunity_id text, title text, provider text, clicks bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_from timestamptz := coalesce(p_from, now() - interval '7 days');
  v_to timestamptz := coalesce(p_to, now());
  v_filtered boolean := p_filter_campaign_id IS NOT NULL
                     OR p_filter_channel_id IS NOT NULL
                     OR p_filter_unattributed IS TRUE;
BEGIN
  IF NOT coalesce(public.is_backoffice_admin(), false) THEN
    RAISE EXCEPTION 'get_command_center_opportunity_interest: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_attribution_filter(p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);
  IF v_to <= v_from THEN
    RAISE EXCEPTION 'Período inválido' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  WITH events AS (
    SELECT e.entity_type,
      coalesce(e.entity_id, CASE
        WHEN e.unified_opportunity_id ~ ('^' || CASE e.entity_type WHEN 'partner_opportunity' THEN 'partner_' ELSE 'mec_' END || '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        THEN substring(e.unified_opportunity_id FROM position('_' IN e.unified_opportunity_id) + 1)::uuid
      END) AS resolved_id,
      e.event_count
    FROM public.engagement_events e
    WHERE e.event_type = 'card_click' AND (e.source = 'card' OR e.source LIKE 'click:%')
      AND e.entity_type IN ('partner_opportunity', 'mec_opportunity')
      AND e.occurred_at >= v_from AND e.occurred_at < v_to
      -- Recorte first-touch: só com filtro ativo, e aí só cliques de logados.
      AND (NOT v_filtered OR (e.user_id IS NOT NULL AND public.matches_first_touch_attribution(
            e.user_id, p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed)))
  ), totals AS (
    SELECT e.entity_type, e.resolved_id, sum(e.event_count)::bigint AS clicks
    FROM events e WHERE e.resolved_id IS NOT NULL
    GROUP BY e.entity_type, e.resolved_id
  ), resolved AS (
    SELECT 'partner_' || po.id::text AS opportunity_id, po.name::text AS title,
      i.name::text AS provider, t.clicks
    FROM totals t JOIN public.partner_opportunities po ON po.id = t.resolved_id
      JOIN public.institutions i ON i.id = po.institution_id
    WHERE t.entity_type = 'partner_opportunity'
    UNION ALL
    SELECT 'mec_' || o.id::text, concat(c.course_name, ' — ', upper(o.opportunity_type), ' ', o.year, '/', o.semester),
      i.name::text, t.clicks
    FROM totals t JOIN public.opportunities o ON o.id = t.resolved_id
      JOIN public.courses c ON c.id = o.course_id
      JOIN public.campus ca ON ca.id = c.campus_id
      JOIN public.institutions i ON i.id = ca.institution_id
    WHERE t.entity_type = 'mec_opportunity'
  )
  SELECT r.opportunity_id, r.title, r.provider, r.clicks FROM resolved r
  ORDER BY r.clicks DESC, r.title, r.opportunity_id
  LIMIT greatest(1, least(coalesce(p_limit, 10), 100));
END;
$function$
;

-- ACL identical to main (20261016140000): the guard is is_backoffice_admin(), so service_role never needed EXECUTE.
REVOKE ALL ON FUNCTION public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean) FROM PUBLIC,anon,partner; GRANT EXECUTE ON FUNCTION public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean) TO authenticated;
COMMENT ON FUNCTION public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean) IS
  'TP-1 / handoff TP-2 0cb07420: ranking por SUM(event_count), apenas card_click de fonte card ou click:<surface> (TP-D D-l); período [from,to), sem legado dual-write, favoritos, views ou redirects. Recorte opcional por campanha/divulgador first-touch (p_filter_*); com recorte ativo só entram cliques de usuários logados.';