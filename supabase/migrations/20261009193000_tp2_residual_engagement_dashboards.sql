-- TP-2 revision 2: residual read paths only. No foundation, backfill or writer changes.
-- Production and staging signatures/ACLs checked 2026-10-09.
-- Migration is transactional; DROP VIEW uses RESTRICT, never CASCADE.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_tp2_partner_funnel(p_partner_id uuid DEFAULT NULL, p_days_ago integer DEFAULT NULL)
RETURNS TABLE(partner_id uuid, partner_name text, total_unique_clicks bigint,
 total_applications_started bigint, total_applications_completed bigint, total_card_clicks bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
 v_admin boolean := auth.role() = 'service_role' OR public.is_backoffice_admin() OR EXISTS (
 SELECT 1 FROM public.user_permissions p WHERE p.user_id=auth.uid() AND p.permission='Parceiros');
 v_from timestamptz := CASE WHEN p_days_ago IS NULL THEN NULL ELSE now()-make_interval(days=>p_days_ago) END;
BEGIN
 IF NOT v_admin AND NOT EXISTS (SELECT 1 FROM public.partners_users pu WHERE pu.user_id=auth.uid()) THEN
  RAISE EXCEPTION 'Access denied' USING ERRCODE='42501';
 END IF;
 IF p_days_ago IS NOT NULL AND p_days_ago<1 THEN RAISE EXCEPTION 'Invalid period' USING ERRCODE='22023'; END IF;
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
  WHERE e.event_type='card_click' AND (v_from IS NULL OR e.occurred_at>=v_from) AND e.occurred_at<=now()
  GROUP BY po.institution_id
 ), applications AS (
  SELECT po.institution_id,COUNT(DISTINCT sa.user_id) AS started,
   COUNT(DISTINCT sa.user_id) FILTER (WHERE lower(sa.status) IN ('submitted','redirected')) AS completed
  FROM public.student_applications sa JOIN public.partner_opportunities po ON po.id=sa.partner_id
  JOIN allowed_institutions i ON i.id=po.institution_id
  WHERE (v_from IS NULL OR sa.created_at>=v_from) AND sa.created_at<=now()
  GROUP BY po.institution_id
 )
 SELECT i.id,i.name,COALESCE(c.users,0),COALESCE(a.started,0),COALESCE(a.completed,0),COALESCE(c.events,0)
 FROM allowed_institutions i LEFT JOIN clicks c ON c.institution_id=i.id
 LEFT JOIN applications a ON a.institution_id=i.id ORDER BY COALESCE(a.completed,0) DESC,i.name;
END;
$$;
REVOKE ALL ON FUNCTION public.get_tp2_partner_funnel(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_tp2_partner_funnel(uuid,integer) TO authenticated,service_role;

-- Staging has a six-column opportunity view; PROD has a five-column institution view.
-- Both have no dependent SQL views (pg_depend checked); RESTRICT protects unknown dependencies.
DROP VIEW IF EXISTS public.vw_partner_funnel;
CREATE VIEW public.vw_partner_funnel WITH (security_invoker=true) AS
 SELECT * FROM public.get_tp2_partner_funnel(NULL,NULL);
REVOKE ALL ON public.vw_partner_funnel FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.vw_partner_funnel TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.get_partner_redirect_users(p_partner_id uuid DEFAULT NULL)
RETURNS TABLE(user_id uuid, full_name text, whatsapp text, redirect_url text, created_at timestamptz,
city text, state text, education text, age integer, neighborhood text, street text,
street_number text, complement text, education_year text, zip_code text, country text,
course_interest text[], preferred_shifts text[], university_preference text, program_preference text,
per_capita_income numeric, quota_types text[], partner_id uuid, partner_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_admin boolean := auth.role() = 'service_role' OR public.is_backoffice_admin() OR EXISTS (
 SELECT 1 FROM public.user_permissions p WHERE p.user_id=auth.uid() AND p.permission='Parceiros');
BEGIN
 IF NOT v_admin AND NOT EXISTS (SELECT 1 FROM public.partners_users pu WHERE pu.user_id=auth.uid()) THEN
  RAISE EXCEPTION 'Access denied' USING ERRCODE='42501';
 END IF;
 RETURN QUERY SELECT up.id,up.full_name::text,au.phone::text,e.destination_url,e.occurred_at,
 up.city,up.state,up.education,up.age,up.neighborhood,up.street,up.street_number,up.complement,
 up.education_year,up.zip_code,up.country,upr.course_interest,upr.preferred_shifts,
 upr.university_preference,upr.program_preference,ui.per_capita_income,upr.quota_types,po.id,po.name
 FROM public.engagement_events e
 JOIN public.partner_opportunities po ON e.entity_type='partner_opportunity'
  AND COALESCE(e.entity_id::text,regexp_replace(e.unified_opportunity_id,'^partner_',''))=po.id::text
 JOIN public.institutions i ON i.id=po.institution_id
 JOIN public.user_profiles up ON up.id=e.user_id
 LEFT JOIN auth.users au ON au.id=e.user_id
 LEFT JOIN public.user_preferences upr ON upr.user_id=e.user_id
 LEFT JOIN public.user_income ui ON ui.user_id=e.user_id
 WHERE e.event_type='redirect' AND (p_partner_id IS NULL OR po.id=p_partner_id)
  AND (v_admin OR EXISTS (SELECT 1 FROM public.partners_users pu WHERE pu.user_id=auth.uid() AND pu.partner_id=i.id))
 ORDER BY e.occurred_at DESC,e.event_id;
END;
$$;
REVOKE ALL ON FUNCTION public.get_partner_redirect_users(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_partner_redirect_users(uuid) TO authenticated,service_role;

-- Explicit institution endpoint: portal inputs are institution IDs, not opportunity IDs.
CREATE OR REPLACE FUNCTION public.get_partner_institution_redirect_users(p_institution_id uuid)
RETURNS TABLE(user_id uuid, full_name text, whatsapp text, redirect_url text, created_at timestamptz,
city text, state text, education text, age integer, neighborhood text, street text,
street_number text, complement text, education_year text, zip_code text, country text,
course_interest text[], preferred_shifts text[], university_preference text, program_preference text,
per_capita_income numeric, quota_types text[], partner_id uuid, partner_name text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
 SELECT r.* FROM public.get_partner_redirect_users(NULL) r
 JOIN public.partner_opportunities po ON po.id=r.partner_id WHERE po.institution_id=p_institution_id;
$$;
REVOKE ALL ON FUNCTION public.get_partner_institution_redirect_users(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_partner_institution_redirect_users(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.get_mec_engagement_dashboard(p_entity_id text DEFAULT NULL,p_days_ago integer DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_result jsonb; v_from timestamptz:=CASE WHEN p_days_ago IS NULL THEN NULL ELSE now()-make_interval(days=>p_days_ago) END;
BEGIN
 IF NOT (auth.role()='service_role' OR public.is_backoffice_admin() OR EXISTS (
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
 RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_mec_engagement_dashboard(text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_mec_engagement_dashboard(text,integer) TO authenticated,service_role;

COMMENT ON FUNCTION public.get_mec_engagement_dashboard(text,integer) IS
'TP-2: raw weighted events and distinct users are separate from causal identity+opportunity pairs. Cohort requires strict view<click<redirect inside selected period, excludes legacy aggregates. Redirect is terminal, not a completed application. Match is not a step.';
COMMENT ON FUNCTION public.get_tp2_partner_funnel(uuid,integer) IS
'TP-2: institution scope; weighted card clicks, unique authenticated clickers and distinct application users. Completion reflects submitted/redirected status of student_applications, never MEC redirects. Partner users see only their own institutions.';
COMMIT;

