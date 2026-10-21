-- Expand only: get_tp2_partner_funnel(uuid,integer) and vw_partner_funnel remain untouched.
CREATE OR REPLACE FUNCTION public.get_tp2_partner_funnel_v2(p_partner_id uuid DEFAULT NULL::uuid, p_from timestamptz DEFAULT NULL::timestamptz, p_to timestamptz DEFAULT NULL::timestamptz)
 RETURNS TABLE(partner_id uuid, partner_name text, total_unique_clicks bigint, total_applications_started bigint, total_applications_completed bigint, total_card_clicks bigint, legacy_external_redirects bigint, last_activity_at timestamptz)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
 v_admin boolean := COALESCE(auth.role(),'') = 'service_role' OR coalesce(public.is_backoffice_admin(),false) OR EXISTS (
 SELECT 1 FROM public.user_permissions p WHERE p.user_id=auth.uid() AND p.permission='Parceiros');
 v_from timestamptz := p_from; v_to timestamptz := least(coalesce(p_to,now()),now());
BEGIN
 IF NOT v_admin AND NOT EXISTS (SELECT 1 FROM public.partners_users pu WHERE pu.user_id=auth.uid()) THEN
  RAISE EXCEPTION 'Access denied' USING ERRCODE='42501';
 END IF;
 PERFORM public.analytics_assert_period(p_from,p_to);
 RETURN QUERY
 WITH allowed_institutions AS (
  SELECT i.id,i.name FROM public.institutions i
  WHERE i.is_partner AND (p_partner_id IS NULL OR i.id=p_partner_id)
   AND (v_admin OR EXISTS (SELECT 1 FROM public.partners_users pu WHERE pu.user_id=auth.uid() AND pu.partner_id=i.id))
 ), clicks AS (
  SELECT po.institution_id, SUM(e.event_count)::bigint AS events,COUNT(DISTINCT e.user_id) AS users
  FROM public.engagement_events e
  JOIN public.partner_opportunities po ON e.entity_type='partner_opportunity'
   AND COALESCE(e.entity_id::text,regexp_replace(e.unified_opportunity_id,'^partner_',''))=po.id::text
  JOIN allowed_institutions i ON i.id=po.institution_id
  WHERE e.event_type='card_click' AND (v_from IS NULL OR e.occurred_at>=v_from) AND e.occurred_at<v_to
  GROUP BY po.institution_id
 ), applications AS (
  SELECT po.institution_id,COUNT(DISTINCT sa.user_id) FILTER(WHERE (v_from IS NULL OR sa.created_at>=v_from) AND sa.created_at<v_to) AS started,
   COUNT(DISTINCT sa.user_id) FILTER (WHERE (l.id IS NOT NULL OR lower(sa.status) IN ('submitted','redirected'))
    AND (v_from IS NULL OR coalesce(l.converted_at,sa.created_at)>=v_from) AND coalesce(l.converted_at,sa.created_at)<v_to) AS completed
  FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id=sa.partner_id
  JOIN allowed_institutions i ON i.id=po.institution_id
  LEFT JOIN public.conversion_match_links l ON l.conversion_kind='application' AND l.conversion_id=sa.id
  GROUP BY po.institution_id
 )
 SELECT i.id,i.name,COALESCE(c.users,0),COALESCE(a.started,0),COALESCE(a.completed,0),COALESCE(c.events,0),
 (SELECT coalesce(sum(e.event_count),0)::bigint FROM public.engagement_events e JOIN public.partner_opportunities po ON po.institution_id=i.id AND coalesce(e.entity_id::text,regexp_replace(e.unified_opportunity_id,'^partner_',''))=po.id::text WHERE e.entity_type='partner_opportunity' AND e.event_type='redirect' AND e.source='legacy_external_redirect' AND (v_from IS NULL OR e.occurred_at>=v_from) AND e.occurred_at<v_to),
 (SELECT max(t) FROM (SELECT e.occurred_at t FROM public.engagement_events e JOIN public.partner_opportunities po ON po.institution_id=i.id AND coalesce(e.entity_id::text,regexp_replace(e.unified_opportunity_id,'^partner_',''))=po.id::text WHERE e.entity_type='partner_opportunity' AND e.occurred_at<=now() UNION ALL SELECT coalesce(sa.updated_at,sa.created_at) FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id=sa.partner_id WHERE po.institution_id=i.id AND coalesce(sa.updated_at,sa.created_at)<=now()) activity)
 FROM allowed_institutions i LEFT JOIN clicks c ON c.institution_id=i.id
 LEFT JOIN applications a ON a.institution_id=i.id ORDER BY COALESCE(a.completed,0) DESC,i.name;
END;
$function$
;
DROP FUNCTION IF EXISTS public.get_mec_engagement_dashboard(text,integer);
CREATE FUNCTION public.get_mec_engagement_dashboard(p_entity_id text DEFAULT NULL::text, p_days_ago integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_result jsonb; v_from timestamptz:=CASE WHEN p_days_ago IS NULL THEN NULL ELSE now()-make_interval(days=>p_days_ago) END;
BEGIN
 IF NOT (COALESCE(auth.role(),'')='service_role' OR coalesce(public.is_backoffice_admin(),false) OR EXISTS (
  SELECT 1 FROM public.user_permissions p WHERE p.user_id=auth.uid() AND p.permission='Dashboard')) THEN
  RAISE EXCEPTION 'Access denied' USING ERRCODE='42501';
 END IF;
 IF p_days_ago IS NOT NULL AND p_days_ago<1 THEN RAISE EXCEPTION 'Invalid period' USING ERRCODE='22023'; END IF;
 WITH all_events AS MATERIALIZED (
  SELECT e.*,COALESCE(e.entity_id::text,regexp_replace(e.unified_opportunity_id,'^mec_','')) AS entity_key,
   CASE WHEN e.user_id IS NOT NULL THEN 'user:'||e.user_id::text ELSE 'anon:'||e.anonymous_id END AS identity_key
  FROM public.engagement_events e WHERE e.entity_type='mec_opportunity' AND e.occurred_at<=now()
   AND (p_entity_id IS NULL OR COALESCE(e.entity_id::text,regexp_replace(e.unified_opportunity_id,'^mec_',''))=p_entity_id)
 ), events AS MATERIALIZED (
  SELECT * FROM all_events WHERE v_from IS NULL OR occurred_at>=v_from
 ), metrics AS (
  SELECT entity_key,
   COALESCE(SUM(event_count) FILTER (WHERE event_type='card_view'),0) AS card_view,
   COALESCE(SUM(event_count) FILTER (WHERE event_type='card_click'),0) AS card_click,
   COALESCE(SUM(event_count) FILTER (WHERE event_type='redirect'),0) AS redirect,
   COUNT(DISTINCT user_id) AS distinct_users,COUNT(DISTINCT identity_key) AS distinct_identities,
   MIN(occurred_at) AS first_observed_at
  FROM events GROUP BY entity_key
 ), live AS MATERIALIZED (
  SELECT * FROM events WHERE left(source,7)<>'legacy_' AND event_count=1
 ), viewers AS (
  SELECT entity_key,identity_key,MIN(occurred_at) AS viewed_at FROM live WHERE event_type='card_view' GROUP BY 1,2
 ), clickers AS (
  SELECT v.entity_key,v.identity_key,MIN(e.occurred_at) AS clicked_at
  FROM viewers v JOIN live e USING(entity_key,identity_key)
  WHERE e.event_type='card_click' AND e.occurred_at>v.viewed_at GROUP BY 1,2
 ), redirectors AS (
  SELECT DISTINCT c.entity_key,c.identity_key FROM clickers c JOIN live e USING(entity_key,identity_key)
  WHERE e.event_type='redirect' AND e.occurred_at>c.clicked_at
 )
 SELECT jsonb_build_object(
  'period',jsonb_build_object('from',v_from,'to',now()),
  'coverage',jsonb_build_object('first_observed_at',(SELECT MIN(occurred_at) FROM all_events),
   'first_view_at',(SELECT MIN(occurred_at) FROM all_events WHERE event_type='card_view' AND left(source,7)<>'legacy_'),
   'legacy_events',(SELECT COALESCE(SUM(event_count),0) FROM events WHERE left(source,7)='legacy_')),
  'totals',jsonb_build_object(
   'card_view',COALESCE(SUM(event_count) FILTER(WHERE event_type='card_view'),0),
   'card_click',COALESCE(SUM(event_count) FILTER(WHERE event_type='card_click'),0),
   'redirect',COALESCE(SUM(event_count) FILTER(WHERE event_type='redirect'),0),
   'distinct_users',COUNT(DISTINCT user_id),'distinct_identities',COUNT(DISTINCT identity_key)),
  'entities',(SELECT COALESCE(jsonb_agg(jsonb_build_object('entity_id',entity_key,'card_view',card_view,
   'card_click',card_click,'redirect',redirect,'distinct_users',distinct_users,
   'distinct_identities',distinct_identities,'first_observed_at',first_observed_at) ORDER BY card_click DESC,entity_key),'[]'::jsonb) FROM metrics),
  'cohort',jsonb_build_object('viewers',(SELECT COUNT(*) FROM viewers),'clickers',(SELECT COUNT(*) FROM clickers),
   'redirectors',(SELECT COUNT(*) FROM redirectors))
 ) INTO v_result FROM events;
 v_result:=jsonb_set(v_result,'{coverage,redirect}',public.analytics_source_coverage('mec_redirect',v_from,now()));
 RETURN v_result;
END;
$function$
;

CREATE FUNCTION public.get_mec_opportunity_volumes(p_from timestamptz DEFAULT NULL,p_to timestamptz DEFAULT NULL,
 p_search text DEFAULT NULL,p_institution_id uuid DEFAULT NULL,p_type text DEFAULT NULL,p_order text DEFAULT 'views',p_limit integer DEFAULT 25,p_offset integer DEFAULT 0)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE result jsonb; term text:=nullif(trim(p_search),'');
BEGIN
 IF NOT (coalesce(auth.role(),'')='service_role' OR coalesce(public.is_backoffice_admin(),false) OR EXISTS(SELECT 1 FROM public.user_permissions WHERE user_id=auth.uid() AND permission='Dashboard')) THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 PERFORM public.analytics_assert_period(p_from,p_to);
 IF p_order IS NULL OR p_order NOT IN ('views','clicks','redirects','users') OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR p_offset IS NULL OR p_offset<0 THEN RAISE EXCEPTION 'Invalid pagination' USING ERRCODE='22023'; END IF;
 WITH events AS (
 SELECT e.*,coalesce(e.entity_id::text,regexp_replace(e.unified_opportunity_id,'^mec_','')) entity_key,
 CASE WHEN e.user_id IS NOT NULL THEN 'user:'||e.user_id ELSE 'anon:'||e.anonymous_id END identity_key
 FROM public.engagement_events e WHERE e.entity_type='mec_opportunity'
 AND e.occurred_at>=coalesce(p_from,'-infinity') AND e.occurred_at<least(coalesce(p_to,now()),now())
 ), metrics AS (
 SELECT entity_key,coalesce(sum(event_count) FILTER(WHERE event_type='card_view'),0) card_view,
 coalesce(sum(event_count) FILTER(WHERE event_type='card_click'),0) card_click,
 coalesce(sum(event_count) FILTER(WHERE event_type='redirect'),0) redirect,
 count(DISTINCT user_id) distinct_users,count(DISTINCT identity_key) distinct_identities FROM events WHERE entity_key IS NOT NULL GROUP BY entity_key
 ), filtered AS (
 SELECT 'mec_'||m.entity_key unified_opportunity_id,m.entity_key entity_id,
 u.title course_title,u.provider_name institution_name,u.location,u.type,u.institution_id,m.card_view,m.card_click,m.redirect,m.distinct_users,m.distinct_identities,
 u.unified_id IS NOT NULL in_catalog FROM metrics m LEFT JOIN public.v_unified_opportunities u ON u.unified_id='mec_'||m.entity_key
 WHERE (p_institution_id IS NULL OR u.institution_id=p_institution_id) AND (p_type IS NULL OR u.type=p_type)
 -- Literal substring search: % and _ are data, never wildcard operators.
 AND (term IS NULL OR strpos(lower(coalesce(u.search_text,'')||' '||coalesce(u.title,'')),lower(term))>0)
 ), page AS (
 SELECT * FROM filtered ORDER BY CASE p_order WHEN 'views' THEN card_view WHEN 'clicks' THEN card_click WHEN 'redirects' THEN redirect ELSE distinct_identities END DESC,unified_opportunity_id
 LIMIT p_limit OFFSET p_offset
 )
 SELECT jsonb_build_object('total_count',(SELECT count(*) FROM filtered),'limit',p_limit,'offset',p_offset,'order',p_order,
 'rows',coalesce((SELECT jsonb_agg(to_jsonb(p)-'institution_id') FROM page p),'[]'::jsonb),
 'non_additive_notice','Pessoas podem aparecer em várias oportunidades; contagens por oportunidade não são aditivas.') INTO result;
 RETURN result;
END $$;
CREATE FUNCTION public.get_mec_volume_institutions(p_from timestamptz DEFAULT NULL,p_to timestamptz DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 -- Same authorization and period checks as get_mec_opportunity_volumes, without aggregating its rows just to discard them.
 IF NOT (coalesce(auth.role(),'')='service_role' OR coalesce(public.is_backoffice_admin(),false) OR EXISTS(SELECT 1 FROM public.user_permissions WHERE user_id=auth.uid() AND permission='Dashboard')) THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 PERFORM public.analytics_assert_period(p_from,p_to);
 SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.name,i.id),'[]'::jsonb) INTO result FROM (
 SELECT DISTINCT u.institution_id id,u.provider_name name FROM public.engagement_events e
 JOIN public.v_unified_opportunities u ON u.unified_id='mec_'||coalesce(e.entity_id::text,regexp_replace(e.unified_opportunity_id,'^mec_',''))
 WHERE e.entity_type='mec_opportunity' AND e.occurred_at>=coalesce(p_from,'-infinity') AND e.occurred_at<least(coalesce(p_to,now()),now()) AND u.institution_id IS NOT NULL) i;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_tp2_partner_funnel_v2(uuid,timestamptz,timestamptz),public.get_mec_engagement_dashboard(text,integer),
 public.get_mec_opportunity_volumes(timestamptz,timestamptz,text,uuid,text,text,integer,integer),public.get_mec_volume_institutions(timestamptz,timestamptz) FROM PUBLIC,anon,partner;
GRANT EXECUTE ON FUNCTION public.get_tp2_partner_funnel_v2(uuid,timestamptz,timestamptz),public.get_mec_engagement_dashboard(text,integer),
 public.get_mec_opportunity_volumes(timestamptz,timestamptz,text,uuid,text,text,integer,integer),public.get_mec_volume_institutions(timestamptz,timestamptz) TO authenticated,service_role;
-- DROP+CREATE discarded the TP-2 comment; restore it and mention the additive coverage.redirect.
COMMENT ON FUNCTION public.get_mec_engagement_dashboard(text,integer) IS
'TP-2: raw weighted events and distinct users are separate from causal identity+opportunity pairs. Cohort requires strict view<click<redirect inside selected period, excludes legacy aggregates. Redirect is terminal, not a completed application. Match is not a step. TP-D: coverage.redirect (additive) reports instrumentation status of the redirect source for the window.';
