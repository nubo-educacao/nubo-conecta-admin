-- Executed only inside caller-owned rollback transaction. Synthetic users @qa-s9.invalid.
DO $test$
DECLARE u uuid := '91dd0000-0000-4000-8000-000000000001'; u2 uuid := '91dd0000-0000-4000-8000-000000000002';
 a uuid := '91dd0000-0000-4000-8000-00000000000a'; po uuid; mec text := 'mec_91dd0000-0000-4000-8000-00000000000b';
 r jsonb; n int; stamp timestamptz; snapshot jsonb;
BEGIN
 SELECT id INTO po FROM public.partner_opportunities ORDER BY id LIMIT 1;
 ASSERT po IS NOT NULL, 'fixture requires partner opportunity';
 INSERT INTO auth.users(id,email) VALUES(u,'tpd-1@qa-s9.invalid'),(u2,'tpd-2@qa-s9.invalid');
 INSERT INTO public.user_permissions(user_id,permission) VALUES(u,'Controle de usuários');
 PERFORM set_config('request.jwt.claim.sub',u::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
 INSERT INTO public.user_profiles(id,full_name,created_at) VALUES(u,'TPD QA 1',now()-interval '10 days'),(u2,'TPD QA 2',now()-interval '10 days') ON CONFLICT(id) DO NOTHING;
 INSERT INTO public.student_applications(id,user_id,partner_id,status) VALUES(a,u,po,'DRAFT');
 ASSERT NOT EXISTS(SELECT 1 FROM public.conversion_match_links WHERE conversion_id=a),'R1 DRAFT not terminal';
 INSERT INTO public.user_opportunity_matches(profile_id,unified_opportunity_id,match_score,generated_at) VALUES(u,'partner_'||po,80,now()-interval '1 hour');
 UPDATE public.student_applications SET status='SUBMITTED' WHERE id=a;
 SELECT converted_at,to_jsonb(l) INTO stamp,snapshot FROM public.conversion_match_links l WHERE conversion_id=a;
 ASSERT snapshot->>'link_status'='matched','R1 UPDATE captures prior match';
 UPDATE public.student_applications SET status='redirected',updated_at=now()+interval '1 day' WHERE id=a;
 ASSERT (SELECT to_jsonb(l)=snapshot FROM public.conversion_match_links l WHERE conversion_id=a),'R1 immutable first classification';
 UPDATE public.student_applications SET status='DRAFT' WHERE id=a;
 UPDATE public.student_applications SET status='SUBMITTED' WHERE id=a;
 ASSERT (SELECT count(*)=1 FROM public.conversion_match_links WHERE conversion_id=a),'idempotent re-entry';
 INSERT INTO public.engagement_events(event_id,event_type,entity_type,entity_id,user_id,source,destination_url) VALUES('tpd-application','redirect','partner_opportunity',po,u,'partner_application','https://qa-s9.invalid/partner');
 ASSERT (SELECT count(*)=1 FROM public.conversion_match_links WHERE user_id=u),'R2 no partner redirect duplicate';
 INSERT INTO public.student_applications(user_id,partner_id,status) VALUES(u2,po,'redirected');
 ASSERT EXISTS(SELECT 1 FROM public.conversion_match_links WHERE user_id=u2 AND link_status='no_prior_match'),'unmatched INSERT terminal preserved';
 INSERT INTO public.user_opportunity_matches(profile_id,unified_opportunity_id,match_score,generated_at) VALUES(u2,'partner_'||po,90,now()+interval '1 hour');
 UPDATE public.student_applications SET status='SUBMITTED' WHERE user_id=u2;
 ASSERT EXISTS(SELECT 1 FROM public.conversion_match_links WHERE user_id=u2 AND link_status='no_prior_match'),'no retroactive match after submission';
 INSERT INTO public.engagement_events(event_id,event_type,entity_type,unified_opportunity_id,user_id,source,destination_url) VALUES('tpd-mec','redirect','mec_opportunity',mec,u,'home_para_voce','https://qa-s9.invalid/mec');
 ASSERT EXISTS(SELECT 1 FROM public.conversion_match_links WHERE user_id=u AND terminal_path='mec_redirect' AND link_status='no_prior_match'),'MEC unmatched ledger';
 INSERT INTO auth.sessions(id,user_id,created_at,refreshed_at) VALUES(gen_random_uuid(),u,now()-interval '1 second',((now()-interval '1 second') AT TIME ZONE 'UTC'));
 INSERT INTO public.chat_messages(user_id,sender,content,workflow,created_at) VALUES(u,'user','oi','chat',now()-interval '1 second'),(u2,'user','system_intent: test','system_intent',now()-interval '1 second');
 ASSERT EXISTS(SELECT 1 FROM public.active_user_ids(now()-interval '1 day',now()+interval '1 minute') x WHERE x.user_id=u),'R3 live after cron';
 PERFORM public.capture_user_activity_days((now() AT TIME ZONE 'America/Sao_Paulo')::date,(now() AT TIME ZONE 'America/Sao_Paulo')::date);
 SELECT count(*) INTO n FROM public.active_user_ids(now()-interval '1 day',now()+interval '1 minute');
 PERFORM public.capture_user_activity_days((now() AT TIME ZONE 'America/Sao_Paulo')::date,(now() AT TIME ZONE 'America/Sao_Paulo')::date);
 ASSERT n=(SELECT count(*) FROM public.active_user_ids(now()-interval '1 day',now()+interval '1 minute')),'live + persisted distinct';
 ASSERT EXISTS(SELECT 1 FROM public.user_activity_days WHERE user_id=u AND sources @> ARRAY['session','engagement','chat']),'union sources';
 ASSERT NOT EXISTS(SELECT 1 FROM public.user_activity_days WHERE user_id=u2 AND 'chat'=ANY(sources)),'exclude system_intent';
 INSERT INTO public.engagement_events(event_id,event_type,entity_type,entity_id,user_id,source,occurred_at) VALUES('tpd-click','card_click','partner_opportunity',po,u,'click:home_para_voce',now()-interval '1 second');
 SELECT sum(clicks) INTO n FROM public.get_command_center_opportunity_interest(now()-interval '1 day',now()+interval '1 minute',100);
 INSERT INTO public.engagement_events(event_id,event_type,entity_type,entity_id,user_id,source,event_count) VALUES('tpd-legacy','card_click','partner_opportunity',po,u,'legacy_partners_click_aggregate',100);
 ASSERT n=(SELECT sum(clicks) FROM public.get_command_center_opportunity_interest(now()-interval '1 day',now()+interval '1 minute',100)),'D-l excludes legacy';
 ASSERT n>=1,'D-l counts new source';
 r:=public.get_product_global_funnel();
 ASSERT jsonb_array_length(r->'totals_by_step')=3,'global totals shape';
 ASSERT (r#>>'{totals_by_step,2,distinct_identities}')::int <= (r#>>'{totals_by_step,2,domain_identity_sum}')::int,'R8 union people';
 r:=public.get_command_center_nsm();
 ASSERT r->'active_users_source'->>'deduplicated_total'=r->>'active_users','NSM denominator union';
 ASSERT (r#>>'{referrals,total}')::int=(r#>>'{referrals,composition,mec_redirect}')::int+(r#>>'{referrals,composition,partner_redirected}')::int+(r#>>'{referrals,composition,partner_submitted}')::int,'NSM excludes legacy';
 r:=public.get_product_l1_metrics(); ASSERT r->'time_to_first_application'->>'basis'='profile_created_to_application_started','L1 time basis';
 r:=public.get_product_l2_metrics(); ASSERT r#>'{engine_reach,mec}' IS NOT NULL AND r#>'{engine_reach,partner}' IS NOT NULL,'R9 domain reach';
 ASSERT r#>>'{match_contribution,untimed_association,label}'='associação sem ordem temporal','L2 separate history';
 r:=public.get_mec_opportunity_volumes(p_offset=>999999); ASSERT r->'rows'='[]'::jsonb AND r->>'total_count' IS NOT NULL,'empty page retains total';
 r:=public.get_mec_engagement_dashboard(NULL,NULL); ASSERT r#>>'{coverage,redirect,status}'='unknown','R5 no deployment receipt';
 r:=public.analytics_source_coverage('mec_redirect',now()-interval '1 day',now());
 ASSERT r->>'status'='unknown','unknown coverage';
 UPDATE public.analytics_instrumentation_coverage SET verified_since=now()-interval '1 hour',evidence_ref='rollback-test-only' WHERE source='mec_redirect';
 ASSERT public.analytics_source_coverage('mec_redirect',now()-interval '1 day',now())->>'status'='partial','crossing coverage';
 ASSERT public.analytics_source_coverage('mec_redirect',now()-interval '2 day',now()-interval '1 day')->>'status'='not_instrumented','before coverage';
 ASSERT public.analytics_source_coverage('mec_redirect',now()-interval '30 minute',now())->>'status'='instrumented','covered even without own events';
 BEGIN PERFORM public.get_product_global_funnel(now(),now()-interval '1 day'); RAISE EXCEPTION 'invalid period accepted'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 BEGIN PERFORM public.get_mec_opportunity_volumes(p_order=>'injection'); RAISE EXCEPTION 'invalid order accepted'; EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 ASSERT NOT has_function_privilege('anon','public.get_product_global_funnel(timestamptz,timestamptz,uuid,uuid,boolean)','EXECUTE'),'anon denied';
 ASSERT NOT has_function_privilege('authenticated','public.capture_user_activity_days(date,date)','EXECUTE'),'internal helper closed';
 ASSERT NOT has_table_privilege('authenticated','public.analytics_conversion_capture_failures','SELECT'),'failure audit API closed';
 ASSERT NOT has_function_privilege('service_role','public.active_user_ids(timestamptz,timestamptz)','EXECUTE'),'unused helper service grant revoked';
 ASSERT (SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('public.user_activity_days'::regclass,'public.conversion_match_links'::regclass,'public.analytics_instrumentation_coverage'::regclass,'public.analytics_conversion_capture_failures'::regclass)),'RLS';
END $test$;

-- R1/R2 fail-open: constraint failure is forced only inside a subtransaction.
DO $failure$
DECLARE u uuid:='91dd0000-0000-4000-8000-000000000001';po uuid;app uuid:=gen_random_uuid();event uuid:=gen_random_uuid();
BEGIN
 SELECT id INTO po FROM public.partner_opportunities ORDER BY id LIMIT 1;
 BEGIN
  ALTER TABLE public.conversion_match_links ADD CONSTRAINT tpd_force_failure CHECK(false) NOT VALID;
  INSERT INTO public.student_applications(id,user_id,partner_id,status) VALUES(app,u,po,'DRAFT');
  UPDATE public.student_applications SET status='SUBMITTED' WHERE id=app;
  INSERT INTO public.engagement_events(id,event_id,event_type,entity_type,unified_opportunity_id,user_id,source,destination_url)
  VALUES(event,'tpd-forced-failure','redirect','mec_opportunity','mec_91dd0000-0000-4000-8000-00000000000b',u,'home_para_voce','https://qa-s9.invalid/mec');
  ASSERT EXISTS(SELECT 1 FROM public.student_applications WHERE id=app AND status='SUBMITTED'),'fail-open UPDATE original retained';
  ASSERT EXISTS(SELECT 1 FROM public.engagement_events WHERE id=event),'fail-open INSERT original retained';
  ASSERT NOT EXISTS(SELECT 1 FROM public.conversion_match_links WHERE conversion_id IN(app,event)),'failed snapshots never fabricated';
  ALTER TABLE public.conversion_match_links DROP CONSTRAINT tpd_force_failure;
  ASSERT EXISTS(SELECT 1 FROM public.analytics_conversion_capture_failures WHERE conversion_id=app),'capture failure observable';
  UPDATE public.student_applications SET status='DRAFT' WHERE id=app;
  UPDATE public.student_applications SET status='SUBMITTED' WHERE id=app;
  ASSERT NOT EXISTS(SELECT 1 FROM public.conversion_match_links WHERE conversion_id=app),'failed snapshot never reconstructed from current match';
 END;
END $failure$;

-- R3 timezone, zero denominator, R4 partner isolation and R6 first-touch.
DO $security$
DECLARE u uuid:='91dd0000-0000-4000-8000-000000000002';inst uuid;result jsonb;v record;
BEGIN
 SELECT institution_id INTO inst FROM public.partner_opportunities ORDER BY id LIMIT 1;
 PERFORM set_config('request.jwt.claim.sub',u::text,true);
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
 BEGIN PERFORM public.get_product_global_funnel();RAISE EXCEPTION 'nonadmin allowed';EXCEPTION WHEN SQLSTATE '42501' THEN NULL;END;
 BEGIN PERFORM public.get_command_center_nsm();RAISE EXCEPTION 'nonadmin NSM allowed';EXCEPTION WHEN SQLSTATE '42501' THEN NULL;END;
 BEGIN PERFORM public.get_product_l1_metrics();RAISE EXCEPTION 'nonadmin L1 allowed';EXCEPTION WHEN SQLSTATE '42501' THEN NULL;END;
 BEGIN PERFORM public.get_product_l2_metrics();RAISE EXCEPTION 'nonadmin L2 allowed';EXCEPTION WHEN SQLSTATE '42501' THEN NULL;END;
 BEGIN PERFORM public.get_mec_opportunity_volumes();RAISE EXCEPTION 'nonadmin MEC allowed';EXCEPTION WHEN SQLSTATE '42501' THEN NULL;END;
 BEGIN PERFORM public.get_tp2_partner_funnel_v2();RAISE EXCEPTION 'nonpartner B2B allowed';EXCEPTION WHEN SQLSTATE '42501' THEN NULL;END;
 INSERT INTO public.partners_users(user_id,partner_id) VALUES(u,inst);
 ASSERT NOT EXISTS(SELECT 1 FROM public.get_tp2_partner_funnel_v2() f WHERE f.partner_id<>inst),'partners_users institution isolation';
 ASSERT NOT EXISTS(SELECT 1 FROM public.get_tp2_partner_funnel() f WHERE f.partner_id<>inst),'v1 preserved institution isolation';
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','service_role')::text,true);
 ASSERT (SELECT from_at='2026-07-01 03:00Z'::timestamptz FROM public.analytics_semester_range('2026-S2')),'BRT semester boundary';
 BEGIN PERFORM public.get_command_center_nsm('invalid');RAISE EXCEPTION 'invalid semester accepted';EXCEPTION WHEN SQLSTATE '22023' THEN NULL;END;
 BEGIN PERFORM public.get_product_l2_metrics(p_filter_campaign_id=>inst,p_filter_unattributed=>true);RAISE EXCEPTION 'mixed first touch accepted';EXCEPTION WHEN SQLSTATE '22023' THEN NULL;END;
 result:=public.get_product_l1_metrics('2000-01-01','2000-01-02');
 ASSERT result#>'{cloudinha_adoption,rate}'='null'::jsonb,'zero denominator null';
 FOR v IN SELECT proname,oid FROM pg_proc WHERE pronamespace='public'::regnamespace AND
 proname IN('get_product_global_funnel','get_command_center_nsm','get_product_l1_metrics','get_product_l2_metrics','get_tp2_partner_funnel_v2','get_mec_opportunity_volumes','get_mec_volume_institutions','get_mec_engagement_dashboard','get_command_center_opportunity_interest') LOOP
  ASSERT NOT has_function_privilege('anon',v.oid,'EXECUTE'),'anon cannot execute '||v.proname;
  ASSERT (SELECT count(*)=1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname=v.proname),'single signature '||v.proname;
 END LOOP;
END $security$;

-- R7/R8: observed volumes are non-monotone; identities have namespaces and global union.
DO $volumes$
DECLARE u uuid:='91dd0000-0000-4000-8000-000000000001';po uuid;r jsonb;row jsonb;
BEGIN
 SELECT id INTO po FROM public.partner_opportunities ORDER BY id LIMIT 1;
 INSERT INTO public.engagement_events(event_id,event_type,entity_type,entity_id,unified_opportunity_id,user_id,anonymous_id,source,event_count,occurred_at,destination_url)
 VALUES
 ('tpd-union-partner','card_view','partner_opportunity',po,NULL,u,NULL,'view:home_para_voce',1,'2001-01-01',NULL),
 ('tpd-union-mec','card_view','mec_opportunity',NULL,'mec_91dd0000-0000-4000-8000-00000000000b',u,NULL,'view:home_para_voce',2,'2001-01-01',NULL),
 ('tpd-union-anon','card_view','partner_opportunity',po,NULL,NULL,u::text,'view:home_para_voce',3,'2001-01-01',NULL),
 ('tpd-volume-click','card_click','partner_opportunity',po,NULL,u,NULL,'click:home_para_voce',1,'2001-01-01',NULL),
 ('tpd-volume-terminal','redirect','partner_opportunity',po,NULL,u,NULL,'legacy_external_redirect',7,'2001-01-01','https://qa-s9.invalid/external');
 r:=public.get_product_global_funnel('2001-01-01','2001-01-02');
 ASSERT (r#>>'{totals_by_step,0,events}')::int=6,'SUM event_count';
 ASSERT (r#>>'{totals_by_step,0,distinct_identities}')::int=2,'user/anon namespace and global union';
 ASSERT (r#>>'{totals_by_step,0,domain_identity_sum}')::int=3,'domain sum labelled separately';
 ASSERT (r#>>'{domains,partner,steps,2,events}')::int=7,'legacy terminal is additive events';
 ASSERT (r#>>'{domains,partner,volume_ratios,1,events_ratio}')::numeric=7,'R7 volume ratio 700% not clamped';
 r:=public.get_mec_opportunity_volumes('2001-01-01','2001-01-02',p_limit=>1);
 ASSERT (r->>'total_count')::int=1,'MEC total count';
 row:=r->'rows'->0;
 ASSERT row->>'entity_id'='91dd0000-0000-4000-8000-00000000000b','MEC UUID textual without prefix';
 ASSERT row->>'in_catalog'='false','out-of-catalog opportunity retained';
 r:=public.get_mec_opportunity_volumes('2001-01-01','2001-01-02',p_search=>'%');
 ASSERT r->'rows'='[]'::jsonb,'literal percent is not wildcard';
 r:=public.get_product_global_funnel('2001-01-01','2001-01-02',p_filter_campaign_id=>'91dd0000-0000-4000-8000-0000000000cc');
 ASSERT (r#>>'{totals_by_step,0,events}')::int=0,'first-touch and anonymous exclusion';
END $volumes$;

-- R3/R9: UTC timestamps cross BRT midnight; dependent matches never become parent reach.
DO $families$
DECLARE u uuid:='91dd0000-0000-4000-8000-000000000001';u2 uuid:='91dd0000-0000-4000-8000-000000000002';
 d1 uuid:='91dd0000-0000-4000-8000-000000000003';d2 uuid:='91dd0000-0000-4000-8000-000000000004';
 before_metrics jsonb; after_metrics jsonb; r jsonb;
BEGIN
 PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 before_metrics:=public.get_product_l2_metrics();
 INSERT INTO auth.users(id,email) VALUES(d1,'tpd-3@qa-s9.invalid'),(d2,'tpd-4@qa-s9.invalid');
 INSERT INTO public.user_profiles(id,full_name,isdependent,parent_user_id) VALUES(d1,'TPD dependent A',true,u),(d2,'TPD dependent B',true,u2) ON CONFLICT(id) DO UPDATE SET isdependent=true,parent_user_id=excluded.parent_user_id;
 INSERT INTO public.user_opportunity_matches(profile_id,unified_opportunity_id,match_score,generated_at)
 VALUES(d1,'mec_tpd_dependent',99,now()-interval '1 day'),(d2,'partner_tpd_dependent',98,now()-interval '1 day');
 after_metrics:=public.get_product_l2_metrics();
 ASSERT after_metrics->'engine_reach'=before_metrics->'engine_reach','R9 dependents excluded from both family numerators';
 ASSERT (after_metrics#>>'{coverage,excluded_unresolved_profile}')::int=(before_metrics#>>'{coverage,excluded_unresolved_profile}')::int+2,'R9 excluded profile coverage';
 INSERT INTO auth.sessions(id,user_id,created_at,refreshed_at) VALUES(gen_random_uuid(),u2,'2026-01-02 02:59Z','2026-01-02 03:01');
 PERFORM public.capture_user_activity_days('2026-01-01','2026-01-02');
 ASSERT (SELECT count(*)=2 FROM public.user_activity_days WHERE user_id=u2 AND activity_date IN ('2026-01-01','2026-01-02') AND 'session'=ANY(sources)),'refreshed_at UTC before BRT day';
 r:=public.get_product_l1_metrics('2026-10-01','2026-10-02');
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r->'retention_by_semester') s WHERE s->>'semester'='2026-S1'),'retention starts in selected semester';
END $families$;

-- L1 quantiles use application start, independently from terminal snapshot time.
DO $quantiles$
DECLARE r jsonb;
BEGIN
 UPDATE public.user_profiles SET created_at='2000-01-01' WHERE id::text IN ('91dd0000-0000-4000-8000-000000000001','91dd0000-0000-4000-8000-000000000002');
 UPDATE public.student_applications SET created_at='2000-01-11' WHERE id='91dd0000-0000-4000-8000-00000000000a';
 UPDATE public.student_applications SET created_at='2000-01-21' WHERE user_id='91dd0000-0000-4000-8000-000000000002';
 r:=public.get_product_l1_metrics('2000-01-01','2000-02-01');
 ASSERT (r#>>'{time_to_first_application,n}')::int=2,'L1 first-start cohort size';
 ASSERT (r#>>'{time_to_first_application,median_days}')::numeric=15,'L1 median start days';
 ASSERT (r#>>'{time_to_first_application,p75_days}')::numeric=17.5,'L1 p75 start days';
END $quantiles$;
