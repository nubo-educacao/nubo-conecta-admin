
-- Shared canonical observation stream. Historical application created_at is only a proxy.
CREATE FUNCTION public.analytics_observations(p_from timestamptz,p_to timestamptz)
 RETURNS TABLE(domain text,step text,user_id uuid,identity_key text,n bigint,observed_at timestamptz,path text,surface text,time_basis text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 WITH activation AS (SELECT capture_started_at started FROM public.analytics_instrumentation_coverage WHERE source='conversion_ledger'),
 applications AS (
 SELECT l.user_id,l.converted_at at_time,l.terminal_path path,'captured_terminal'::text basis
 FROM public.conversion_match_links l WHERE l.conversion_kind='application'
 UNION ALL
 SELECT s.user_id,coalesce(f.converted_at,s.created_at),coalesce(f.terminal_path,CASE lower(s.status) WHEN 'redirected' THEN 'partner_redirected' ELSE 'partner_submitted' END),
 CASE WHEN f.conversion_id IS NULL AND s.created_at<(SELECT started FROM activation) THEN 'created_at_proxy' ELSE 'post_capture_missing_snapshot' END
 FROM public.student_applications s LEFT JOIN public.analytics_conversion_capture_failures f ON f.conversion_kind='application' AND f.conversion_id=s.id WHERE (f.conversion_id IS NOT NULL OR lower(s.status) IN ('redirected','submitted'))
 AND NOT EXISTS(SELECT 1 FROM public.conversion_match_links l WHERE l.conversion_kind='application' AND l.conversion_id=s.id)
 ), observations AS (
 SELECT CASE e.entity_type WHEN 'mec_opportunity' THEN 'mec' ELSE 'partner' END domain,
 CASE WHEN e.event_type='redirect' THEN 'terminal' ELSE e.event_type END step,e.user_id,
 CASE WHEN e.user_id IS NOT NULL THEN 'user:'||e.user_id ELSE 'anon:'||e.anonymous_id END identity_key,
 e.event_count::bigint n,e.occurred_at observed_at,
 CASE WHEN e.event_type='redirect' THEN CASE WHEN e.entity_type='mec_opportunity' THEN 'mec_redirect' ELSE 'legacy_external_redirect' END END path,
 CASE WHEN e.source LIKE 'view:%' THEN substring(e.source FROM 6) WHEN e.source LIKE 'click:%' THEN substring(e.source FROM 7)
 WHEN e.event_type='card_click' AND coalesce(e.source,'') NOT LIKE 'legacy_%' THEN 'não instrumentado por superfície' ELSE e.source END surface,
 'event_timestamp'::text time_basis
 FROM public.engagement_events e WHERE e.entity_type IN ('mec_opportunity','partner_opportunity')
 AND (e.event_type IN ('card_view','card_click') OR (e.event_type='redirect' AND
 ((e.entity_type='mec_opportunity' AND coalesce(e.source,'') NOT LIKE 'legacy_%') OR (e.entity_type='partner_opportunity' AND e.source='legacy_external_redirect'))))
 UNION ALL SELECT 'partner','terminal',a.user_id,'user:'||a.user_id,1::bigint,a.at_time,a.path,NULL,a.basis FROM applications a
 )
 SELECT * FROM observations o WHERE o.observed_at>=coalesce(p_from,'-infinity') AND o.observed_at<least(coalesce(p_to,now()),now())
 $$;

CREATE FUNCTION public.get_product_global_funnel(p_from timestamptz DEFAULT NULL,p_to timestamptz DEFAULT NULL,
 p_filter_campaign_id uuid DEFAULT NULL,p_filter_channel_id uuid DEFAULT NULL,p_filter_unattributed boolean DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE result jsonb; filtered boolean:=p_filter_campaign_id IS NOT NULL OR p_filter_channel_id IS NOT NULL OR p_filter_unattributed IS TRUE;
 cov_mec jsonb; cov_click jsonb;
BEGIN
 PERFORM public.analytics_assert_admin(); PERFORM public.analytics_assert_period(p_from,p_to);
 PERFORM public.assert_attribution_filter(p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed);
 -- Each coverage call scans engagement_events for first_observed_at: resolve once per request, not per row.
 cov_mec:=public.analytics_source_coverage('mec_redirect',p_from,p_to);
 cov_click:=public.analytics_source_coverage('click_surface',p_from,p_to);
 WITH observations AS MATERIALIZED (
 SELECT * FROM public.analytics_observations(p_from,p_to) o WHERE NOT filtered OR
 (o.user_id IS NOT NULL AND public.matches_first_touch_attribution(o.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed))
 ), slots AS (
 SELECT d.domain,s.key,s.label,s.ord,
 CASE WHEN d.domain='mec' AND s.key='terminal' THEN cov_mec
 ELSE jsonb_build_object('status','observed','reason','Volumes observados; não representam coorte sequencial') END coverage
 FROM (VALUES('mec'),('partner')) d(domain) CROSS JOIN (VALUES('card_view','Visualizações',1),('card_click','Cliques',2),('terminal','Encaminhamentos',3)) s(key,label,ord)
 ), counts AS (
 SELECT s.*,coalesce(sum(o.n),0) events,count(DISTINCT o.identity_key) users FROM slots s LEFT JOIN observations o ON o.domain=s.domain AND o.step=s.key GROUP BY s.domain,s.key,s.label,s.ord,s.coverage
 ), domains AS (
 SELECT c.domain,jsonb_build_object('steps',jsonb_agg(jsonb_build_object('key',c.key,'label',c.label,'events',c.events,'users',c.users,'coverage',c.coverage) ORDER BY c.ord),
 'composition_events',CASE WHEN c.domain='partner' THEN (SELECT jsonb_build_object(
 'redirected',coalesce(sum(o.n) FILTER(WHERE path='partner_redirected'),0),
 'submitted',coalesce(sum(o.n) FILTER(WHERE path='partner_submitted'),0),
 'legacy_external_redirect',coalesce(sum(o.n) FILTER(WHERE path='legacy_external_redirect'),0)) FROM observations o WHERE o.domain='partner' AND o.step='terminal') ELSE NULL END,
 'volume_ratios',(SELECT jsonb_agg(jsonb_build_object('from',a.key,'to',b.key,'kind','observed_volume_ratio',
 'events_ratio',CASE WHEN a.events>0 AND coalesce(b.coverage->>'status','') NOT IN ('unknown','partial','not_instrumented') THEN b.events::numeric/a.events END,
 'users_ratio',CASE WHEN a.users>0 AND coalesce(b.coverage->>'status','') NOT IN ('unknown','partial','not_instrumented') THEN b.users::numeric/a.users END) ORDER BY b.ord)
 FROM counts a JOIN counts b ON b.domain=a.domain AND b.ord=a.ord+1 WHERE a.domain=c.domain)) data
 FROM counts c GROUP BY c.domain
 )
 SELECT jsonb_build_object('period',jsonb_build_object('from',p_from,'to',least(coalesce(p_to,now()),now())),
 'unit_note','Eventos são somáveis. Pessoas únicas usam união com namespace user:/anon:. Razões de volumes observados não são conversão de coorte. Candidaturas anteriores à captura usam created_at como proxy de data, não a data de submissão.',
 'domains',(SELECT jsonb_object_agg(domain,data) FROM domains),
 'totals_by_step',(SELECT jsonb_agg(jsonb_build_object('key',s.key,'events',(SELECT coalesce(sum(o.n),0) FROM observations o WHERE o.step=s.key),
 'distinct_identities',(SELECT count(DISTINCT o.identity_key) FROM observations o WHERE o.step=s.key),
 'domain_identity_sum',(SELECT sum(c.users) FROM counts c WHERE c.key=s.key),'people_composition_additive',false,
 'coverage',jsonb_build_object('status','observed','mec_redirect',cov_mec)) ORDER BY s.ord)
 FROM (VALUES('card_view',1),('card_click',2),('terminal',3)) s(key,ord)),
 'by_surface',(SELECT coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) FROM
 (SELECT o.surface,o.domain,coalesce(sum(n) FILTER(WHERE step='card_view'),0) views,coalesce(sum(n) FILTER(WHERE step='card_click'),0) clicks,
 coalesce(sum(n) FILTER(WHERE step='card_click' AND surface<>'não instrumentado por superfície' AND surface NOT LIKE 'legacy_%'),0) clicks_instrumented,
 cov_click coverage FROM observations o WHERE step<>'terminal' GROUP BY surface,domain ORDER BY domain,surface) s))
 INTO result; RETURN result;
END $$;

CREATE FUNCTION public.analytics_semester_range(p_semester text) RETURNS TABLE(semester text,from_at timestamptz,to_at timestamptz)
 LANGUAGE plpgsql STABLE SET search_path=public,pg_temp AS $$
DECLARE s text:=coalesce(p_semester,to_char(now() AT TIME ZONE 'America/Sao_Paulo','YYYY')||'-S'||CASE WHEN extract(month FROM now() AT TIME ZONE 'America/Sao_Paulo')<=6 THEN '1' ELSE '2' END); y int; m int;
BEGIN
 IF s !~ '^[0-9]{4}-S[12]$' THEN RAISE EXCEPTION 'Invalid semester (YYYY-S1/S2)' USING ERRCODE='22023'; END IF;
 y:=left(s,4)::int; m:=CASE right(s,1) WHEN '1' THEN 1 ELSE 7 END;
 RETURN QUERY SELECT s,make_date(y,m,1)::timestamp AT TIME ZONE 'America/Sao_Paulo',(make_date(y,m,1)::timestamp+interval '6 months') AT TIME ZONE 'America/Sao_Paulo';
END $$;

CREATE FUNCTION public.analytics_nsm_window(p_semester text,p_campaign uuid,p_channel uuid,p_unattributed boolean) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE f timestamptz;t timestamptz;semester text;result jsonb; mec_coverage jsonb;
BEGIN
 SELECT r.semester,r.from_at,r.to_at INTO semester,f,t FROM public.analytics_semester_range(p_semester) r;
 mec_coverage:=public.analytics_source_coverage('mec_redirect',f,t);
 WITH active AS MATERIALIZED (
 SELECT a.user_id FROM public.active_user_ids(f,t) a WHERE public.matches_first_touch_attribution(a.user_id,p_campaign,p_channel,p_unattributed)
 ), obs AS MATERIALIZED (
 SELECT * FROM public.analytics_observations(f,t) o WHERE o.step='terminal' AND o.user_id IS NOT NULL AND public.matches_first_touch_attribution(o.user_id,p_campaign,p_channel,p_unattributed)
 ), values AS (
 SELECT (SELECT count(*) FROM active) active,coalesce(sum(n) FILTER(WHERE path<>'legacy_external_redirect'),0) referrals,
 coalesce(sum(n) FILTER(WHERE path='mec_redirect'),0) mec,coalesce(sum(n) FILTER(WHERE path='partner_redirected'),0) redirected,
 coalesce(sum(n) FILTER(WHERE path='partner_submitted'),0) submitted,coalesce(sum(n) FILTER(WHERE path='legacy_external_redirect'),0) legacy FROM obs
 )
 SELECT jsonb_build_object('semester',semester,'range',jsonb_build_object('from',f,'to',t),'active_users',v.active,
 'active_users_source',jsonb_build_object('activity_days',(SELECT count(DISTINCT d.user_id) FROM public.user_activity_days d JOIN active a USING(user_id) WHERE d.activity_date>=(f AT TIME ZONE 'America/Sao_Paulo')::date AND d.activity_date<(t AT TIME ZONE 'America/Sao_Paulo')::date),
 'live_fallback',(SELECT count(DISTINCT l.user_id) FROM public.analytics_live_activity(f,t) l JOIN active a USING(user_id)),'deduplicated_total',v.active),
 'referrals',jsonb_build_object('total',v.referrals,'composition',jsonb_build_object('mec_redirect',v.mec,'partner_redirected',v.redirected,'partner_submitted',v.submitted,'legacy_external_redirect',v.legacy)),
 'per_active_user',CASE WHEN v.active>0 AND mec_coverage->>'status'='instrumented' AND NOT EXISTS(SELECT 1 FROM public.analytics_conversion_capture_failures err WHERE err.converted_at>=f AND err.converted_at<least(t,now()) AND public.matches_first_touch_attribution(err.user_id,p_campaign,p_channel,p_unattributed)) THEN v.referrals::numeric/v.active END,
 'coverage',jsonb_build_object('activity',public.analytics_activity_coverage(),'mec_redirect',mec_coverage,'reason',CASE WHEN v.active=0 THEN 'zero_denominator' WHEN EXISTS(SELECT 1 FROM public.analytics_conversion_capture_failures err WHERE err.converted_at>=f AND err.converted_at<least(t,now()) AND public.matches_first_touch_attribution(err.user_id,p_campaign,p_channel,p_unattributed)) THEN 'capture_failure' WHEN mec_coverage->>'status'<>'instrumented' THEN 'incomplete_mec_coverage' END,
 'application_time_basis',(SELECT jsonb_build_object('captured_terminal',count(*) FILTER(WHERE time_basis='captured_terminal'),'created_at_proxy',count(*) FILTER(WHERE time_basis='created_at_proxy'),'post_capture_missing_snapshot',count(*) FILTER(WHERE time_basis='post_capture_missing_snapshot')) FROM obs WHERE domain='partner')))
 INTO result FROM values v; RETURN result;
END $$;
CREATE FUNCTION public.get_command_center_nsm(p_semester text DEFAULT NULL,p_compare text DEFAULT NULL,
 p_filter_campaign_id uuid DEFAULT NULL,p_filter_channel_id uuid DEFAULT NULL,p_filter_unattributed boolean DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE s text;c text;r jsonb;
BEGIN
 PERFORM public.analytics_assert_admin();PERFORM public.assert_attribution_filter(p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed);
 SELECT semester INTO s FROM public.analytics_semester_range(p_semester);
 c:=coalesce(p_compare,(left(s,4)::int-1)::text||right(s,3));
 r:=public.analytics_nsm_window(s,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed);
 RETURN r||jsonb_build_object('comparison',public.analytics_nsm_window(c,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed),
 'seasonality_note',CASE WHEN right(s,1)<>right(c,1) THEN 'S1 tem SiSU+ProUni; S2 só ProUni' ELSE 'Comparação com o mesmo semestre; coberturas históricas podem diferir' END);
END $$;

CREATE FUNCTION public.get_product_l1_metrics(p_from timestamptz DEFAULT NULL,p_to timestamptz DEFAULT NULL,
 p_filter_campaign_id uuid DEFAULT NULL,p_filter_channel_id uuid DEFAULT NULL,p_filter_unattributed boolean DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 PERFORM public.analytics_assert_admin();PERFORM public.analytics_assert_period(p_from,p_to);PERFORM public.assert_attribution_filter(p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed);
 WITH active AS MATERIALIZED (SELECT a.user_id FROM public.active_user_ids(p_from,p_to) a WHERE public.matches_first_touch_attribution(a.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)),
 talked AS (SELECT count(DISTINCT l.user_id) n FROM public.analytics_live_activity(p_from,p_to) l JOIN active a USING(user_id) WHERE l.source='chat'),
 first_apps AS (SELECT s.user_id,min(s.created_at) at_time FROM public.student_applications s GROUP BY s.user_id),
 durations AS (SELECT extract(epoch FROM (a.at_time-p.created_at))/86400 days FROM first_apps a JOIN public.user_profiles p ON p.id=a.user_id AND NOT coalesce(p.isdependent,false) AND p.parent_user_id IS NULL
 WHERE a.at_time>=coalesce(p_from,'-infinity') AND a.at_time<least(coalesce(p_to,now()),now()) AND a.at_time>=p.created_at AND public.matches_first_touch_attribution(a.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)),
 bounds AS (SELECT coalesce(p_from AT TIME ZONE 'America/Sao_Paulo',(SELECT min(activity_date)::timestamp FROM public.user_activity_days),now() AT TIME ZONE 'America/Sao_Paulo') anchor),
 semesters AS (
 SELECT g.start_at,(g.start_at+interval '6 months') next_at,(g.start_at+interval '12 months') end_at,
 to_char(g.start_at,'YYYY')||'-S'||CASE WHEN extract(month FROM g.start_at)=1 THEN '1' ELSE '2' END semester
 FROM bounds b CROSS JOIN LATERAL generate_series(date_trunc('year',b.anchor)+CASE WHEN extract(month FROM b.anchor)>6 THEN interval '6 months' ELSE interval '0 months' END,
 least(coalesce(p_to,now()),now()) AT TIME ZONE 'America/Sao_Paulo',interval '6 months') g(start_at)
 ), retention AS (
 SELECT s.semester,s.end_at AT TIME ZONE 'America/Sao_Paulo'<=now() complete,count(a.user_id) active,count(b.user_id) retained_next
 FROM semesters s LEFT JOIN LATERAL (
 SELECT x.user_id FROM public.active_user_ids(s.start_at AT TIME ZONE 'America/Sao_Paulo',s.next_at AT TIME ZONE 'America/Sao_Paulo') x
 WHERE public.matches_first_touch_attribution(x.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)) a ON true
 LEFT JOIN LATERAL (SELECT x.user_id FROM public.active_user_ids(s.next_at AT TIME ZONE 'America/Sao_Paulo',s.end_at AT TIME ZONE 'America/Sao_Paulo') x
 WHERE x.user_id=a.user_id AND public.matches_first_touch_attribution(x.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)) b ON true GROUP BY s.semester,s.end_at
 )
 SELECT jsonb_build_object('active_users',(SELECT count(*) FROM active),'cloudinha_adoption',jsonb_build_object('talked',talked.n,'active',(SELECT count(*) FROM active),'n',(SELECT count(*) FROM active),'rate',talked.n::numeric/nullif((SELECT count(*) FROM active),0)),
 'time_to_first_application',(SELECT jsonb_build_object('n',count(*),'median_days',percentile_cont(.5) WITHIN GROUP(ORDER BY days),'p75_days',percentile_cont(.75) WITHIN GROUP(ORDER BY days),'basis','profile_created_to_application_started') FROM durations),
 'retention_by_semester',(SELECT coalesce(jsonb_agg(jsonb_build_object('semester',r.semester,'active',r.active,'retained_next',r.retained_next,'rate',CASE WHEN r.complete THEN r.retained_next::numeric/nullif(r.active,0) END,'complete',r.complete) ORDER BY r.semester),'[]'::jsonb) FROM retention r),
 'coverage',jsonb_build_object('activity',public.analytics_activity_coverage(),'excluded_negative_durations',(SELECT count(*) FROM first_apps a JOIN public.user_profiles p ON p.id=a.user_id WHERE a.at_time<p.created_at AND a.at_time>=coalesce(p_from,'-infinity') AND a.at_time<least(coalesce(p_to,now()),now()) AND public.matches_first_touch_attribution(a.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)),
 'activity_period',public.analytics_activity_period(p_from,p_to),'rates_unit','fraction'))
 INTO result FROM talked; RETURN result;
END $$;

CREATE FUNCTION public.get_product_l2_metrics(p_from timestamptz DEFAULT NULL,p_to timestamptz DEFAULT NULL,
 p_filter_campaign_id uuid DEFAULT NULL,p_filter_channel_id uuid DEFAULT NULL,p_filter_unattributed boolean DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE result jsonb;started timestamptz;
BEGIN
 PERFORM public.analytics_assert_admin();PERFORM public.analytics_assert_period(p_from,p_to);PERFORM public.assert_attribution_filter(p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed);
 SELECT capture_started_at INTO started FROM public.analytics_instrumentation_coverage WHERE source='conversion_ledger';
 WITH active AS MATERIALIZED (SELECT a.user_id FROM public.active_user_ids(p_from,p_to) a WHERE public.matches_first_touch_attribution(a.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)),
 matches AS MATERIALIZED (SELECT m.* FROM public.user_opportunity_matches m JOIN public.user_profiles p ON p.id=m.profile_id AND NOT coalesce(p.isdependent,false) AND p.parent_user_id IS NULL
 WHERE m.generated_at<=now() AND public.matches_first_touch_attribution(p.id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)),
 domains AS (SELECT * FROM (VALUES('mec','mec_'),('partner','partner_')) d(domain,prefix)),
 reach AS (SELECT d.domain,(SELECT count(DISTINCT m.profile_id) FROM matches m JOIN active a ON a.user_id=m.profile_id WHERE starts_with(m.unified_opportunity_id,d.prefix)) n,(SELECT count(*) FROM active) total FROM domains d),
 catalog AS (SELECT d.domain,(SELECT count(DISTINCT m.unified_opportunity_id) FROM matches m JOIN public.v_unified_opportunities u ON u.unified_id=m.unified_opportunity_id WHERE starts_with(u.unified_id,d.prefix)) n,
 (SELECT count(*) FROM public.v_unified_opportunities u WHERE starts_with(u.unified_id,d.prefix)) total FROM domains d),
 temporal AS (SELECT count(*) total,count(*) FILTER(WHERE l.link_status='matched') matched FROM public.conversion_match_links l WHERE l.converted_at>=coalesce(p_from,'-infinity') AND l.converted_at<least(coalesce(p_to,now()),now()) AND public.matches_first_touch_attribution(l.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)),
 untimed AS (SELECT count(*) n FROM public.student_applications s WHERE lower(s.status) IN ('submitted','redirected') AND s.created_at<started AND s.created_at>=coalesce(p_from,'-infinity') AND s.created_at<least(coalesce(p_to,now()),now())
 AND NOT EXISTS(SELECT 1 FROM public.conversion_match_links l WHERE l.conversion_kind='application' AND l.conversion_id=s.id)
 AND public.matches_first_touch_attribution(s.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)
 AND EXISTS(SELECT 1 FROM matches m WHERE m.profile_id=s.user_id AND m.unified_opportunity_id='partner_'||s.partner_id::text))
 SELECT jsonb_build_object('engine_reach',(SELECT jsonb_object_agg(domain,jsonb_build_object('active_with_match',n,'active',total,'rate',n::numeric/nullif(total,0))) FROM reach),
 'catalog_coverage',(SELECT jsonb_object_agg(domain,jsonb_build_object('recommended',n,'catalog',total,'rate',n::numeric/nullif(total,0))) FROM catalog),
 'match_contribution',jsonb_build_object('temporal',(SELECT jsonb_build_object('conversions_with_prior_match',matched,'conversions_total',total,'rate',matched::numeric/nullif(total,0),'since',started,
 'coverage',jsonb_build_object('status','observed','capture_failures',(SELECT count(*) FROM public.analytics_conversion_capture_failures err WHERE err.converted_at>=coalesce(p_from,'-infinity') AND err.converted_at<=now() AND err.converted_at<coalesce(p_to,'infinity') AND public.matches_first_touch_attribution(err.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)),'note','Taxa observada dos snapshots capturados; falhas registradas e perfis não comprovados limitam cobertura, sem reconstrução posterior')) FROM temporal),
 'untimed_association',jsonb_build_object('count',(SELECT n FROM untimed)+(SELECT count(*) FROM public.engagement_events e WHERE e.event_type='redirect' AND e.entity_type='mec_opportunity' AND coalesce(e.source,'') NOT LIKE 'legacy_%' AND e.occurred_at<started AND e.occurred_at>=coalesce(p_from,'-infinity') AND e.occurred_at<least(coalesce(p_to,now()),now()) AND public.matches_first_touch_attribution(e.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed) AND NOT EXISTS(SELECT 1 FROM public.conversion_match_links l WHERE l.conversion_kind='redirect' AND l.conversion_id=e.id) AND EXISTS(SELECT 1 FROM matches m WHERE m.profile_id=e.user_id AND m.unified_opportunity_id=coalesce(e.unified_opportunity_id,'mec_'||e.entity_id::text))),'label','associação sem ordem temporal','scope','Conversões anteriores ao ledger com associação atual; conjunto disjunto do temporal')),
 'scope',jsonb_build_object('snapshot_at',now(),'engine_reach','ativos no período com resultado atual','catalog_coverage','catálogo e recomendações atuais do segmento first-touch; sem reconstrução histórica','identity','auth user = perfil titular comprovado; dependentes não são atribuídos ao titular'),
 'coverage',jsonb_build_object('activity',public.analytics_activity_coverage(),'activity_period',public.analytics_activity_period(p_from,p_to),
 'excluded_unresolved_profile',(SELECT count(*) FROM public.user_opportunity_matches m JOIN public.user_profiles p ON p.id=m.profile_id WHERE (coalesce(p.isdependent,false) OR p.parent_user_id IS NOT NULL) AND public.matches_first_touch_attribution(p.id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed)),
 'post_capture_missing_snapshot',(SELECT count(*) FROM public.analytics_observations(p_from,p_to) o WHERE o.time_basis='post_capture_missing_snapshot' AND public.matches_first_touch_attribution(o.user_id,p_filter_campaign_id,p_filter_channel_id,p_filter_unattributed))))
 INTO result; RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.analytics_observations(timestamptz,timestamptz),public.analytics_semester_range(text),public.analytics_nsm_window(text,uuid,uuid,boolean) FROM PUBLIC,anon,authenticated,partner,service_role;
REVOKE ALL ON FUNCTION public.get_product_global_funnel(timestamptz,timestamptz,uuid,uuid,boolean),public.get_command_center_nsm(text,text,uuid,uuid,boolean),
 public.get_product_l1_metrics(timestamptz,timestamptz,uuid,uuid,boolean),public.get_product_l2_metrics(timestamptz,timestamptz,uuid,uuid,boolean) FROM PUBLIC,anon,partner;
GRANT EXECUTE ON FUNCTION public.get_product_global_funnel(timestamptz,timestamptz,uuid,uuid,boolean),public.get_command_center_nsm(text,text,uuid,uuid,boolean),
 public.get_product_l1_metrics(timestamptz,timestamptz,uuid,uuid,boolean),public.get_product_l2_metrics(timestamptz,timestamptz,uuid,uuid,boolean) TO authenticated,service_role;
