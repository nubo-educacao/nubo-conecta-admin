-- TP-D rev.3: prospective capture only. No historical conversion backfill.
CREATE TABLE public.analytics_instrumentation_coverage(
 source text PRIMARY KEY, verified_since timestamptz, capture_started_at timestamptz,
 evidence_ref text, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.user_activity_days(
 user_id uuid NOT NULL, activity_date date NOT NULL,
 sources text[] NOT NULL CHECK(sources <@ ARRAY['session','engagement','chat']::text[]),
 first_seen_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,activity_date)
);
CREATE INDEX user_activity_days_date_idx ON public.user_activity_days(activity_date,user_id);
CREATE TABLE public.conversion_match_links(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),conversion_kind text NOT NULL CHECK(conversion_kind IN ('application','redirect')),
 conversion_id uuid NOT NULL,user_id uuid NOT NULL,profile_id uuid,unified_opportunity_id text,
 terminal_path text NOT NULL CHECK(terminal_path IN ('mec_redirect','partner_redirected','partner_submitted')),
 converted_at timestamptz NOT NULL,captured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 match_id uuid,match_score numeric(5,2),match_generated_at timestamptz,
 link_status text NOT NULL CHECK(link_status IN ('matched','no_prior_match','unresolved_profile')),
 UNIQUE(conversion_kind,conversion_id),
 CHECK((link_status='matched' AND match_id IS NOT NULL AND match_generated_at IS NOT NULL AND match_generated_at<=converted_at)
    OR (link_status<>'matched' AND match_id IS NULL AND match_score IS NULL AND match_generated_at IS NULL))
);
CREATE INDEX conversion_match_links_period_idx ON public.conversion_match_links(converted_at,user_id);
-- Operational failures, not a second conversion denominator. A lost snapshot must never be retried with a later match.
CREATE TABLE public.analytics_conversion_capture_failures(
 conversion_kind text NOT NULL CHECK(conversion_kind IN ('application','redirect')),
 conversion_id uuid NOT NULL,user_id uuid,terminal_path text NOT NULL,
 converted_at timestamptz NOT NULL,failed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 sqlstate text NOT NULL,PRIMARY KEY(conversion_kind,conversion_id)
);
ALTER TABLE public.analytics_conversion_capture_failures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.analytics_conversion_capture_failures FROM PUBLIC,anon,authenticated,service_role;
ALTER TABLE public.analytics_instrumentation_coverage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_activity_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversion_match_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.analytics_instrumentation_coverage,public.user_activity_days,public.conversion_match_links FROM PUBLIC,anon,authenticated,service_role;

-- Internal primitives: callers are authorized RPCs, cron or table triggers.
CREATE FUNCTION public.analytics_assert_period(p_from timestamptz,p_to timestamptz) RETURNS void
 LANGUAGE plpgsql STABLE SET search_path=public,pg_temp AS $$
BEGIN IF p_from>p_to THEN RAISE EXCEPTION 'Invalid period' USING ERRCODE='22023'; END IF; END $$;

CREATE FUNCTION public.analytics_assert_admin() RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NOT (coalesce(auth.role(),'')='service_role' OR coalesce(public.is_backoffice_admin(),false)) THEN
 RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
END $$;

CREATE FUNCTION public.analytics_live_activity(p_from timestamptz,p_to timestamptz)
 RETURNS TABLE(user_id uuid,activity_at timestamptz,source text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT s.user_id,s.created_at,'session' FROM auth.sessions s WHERE s.created_at>=coalesce(p_from,'-infinity') AND s.created_at<=now() AND s.created_at<coalesce(p_to,'infinity')
 UNION ALL SELECT s.user_id,s.refreshed_at AT TIME ZONE 'UTC','session' FROM auth.sessions s
 WHERE s.refreshed_at>=(coalesce(p_from,'-infinity') AT TIME ZONE 'UTC') AND s.refreshed_at<=(now() AT TIME ZONE 'UTC') AND s.refreshed_at<(coalesce(p_to,'infinity') AT TIME ZONE 'UTC')
 UNION ALL SELECT e.user_id,e.occurred_at,'engagement' FROM public.engagement_events e
 WHERE e.user_id IS NOT NULL AND e.occurred_at>=coalesce(p_from,'-infinity') AND e.occurred_at<=now() AND e.occurred_at<coalesce(p_to,'infinity')
 UNION ALL SELECT c.user_id,c.created_at,'chat' FROM public.chat_messages c WHERE c.user_id IS NOT NULL AND c.sender='user'
 AND c.workflow IS DISTINCT FROM 'system_intent' AND coalesce(c.content,'') !~ '^system_intent:'
 AND coalesce(c.content,'') !~ '"intent_type"\s*:\s*"system_intent"'
 AND c.created_at>=coalesce(p_from,'-infinity') AND c.created_at<=now() AND c.created_at<coalesce(p_to,'infinity')
 $$;


CREATE FUNCTION public.analytics_activity_period(p_from timestamptz,p_to timestamptz) RETURNS jsonb
 LANGUAGE sql STABLE SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('from',date_trunc('day',p_from AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo',
 'to',CASE WHEN p_to IS NULL THEN NULL WHEN p_to=(date_trunc('day',p_to AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo') THEN p_to
 ELSE (date_trunc('day',p_to AT TIME ZONE 'America/Sao_Paulo')+interval '1 day') AT TIME ZONE 'America/Sao_Paulo' END,
 'granularity','day','timezone','America/Sao_Paulo')
 $$;

CREATE FUNCTION public.active_user_ids(p_from timestamptz,p_to timestamptz) RETURNS TABLE(user_id uuid)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE f timestamptz := date_trunc('day',p_from AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo';
 t timestamptz := CASE WHEN p_to IS NULL THEN NULL WHEN p_to=(date_trunc('day',p_to AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo') THEN p_to
 ELSE (date_trunc('day',p_to AT TIME ZONE 'America/Sao_Paulo')+interval '1 day') AT TIME ZONE 'America/Sao_Paulo' END;
BEGIN
 PERFORM public.analytics_assert_period(p_from,p_to);
 RETURN QUERY SELECT d.user_id FROM public.user_activity_days d
 WHERE (f IS NULL OR d.activity_date>=(f AT TIME ZONE 'America/Sao_Paulo')::date)
 AND (t IS NULL OR d.activity_date<(t AT TIME ZONE 'America/Sao_Paulo')::date) AND d.activity_date<=(now() AT TIME ZONE 'America/Sao_Paulo')::date
 UNION SELECT a.user_id FROM public.analytics_live_activity(f,t) a WHERE a.user_id IS NOT NULL;
END $$;

CREATE FUNCTION public.capture_user_activity_days(p_from date,p_to date) RETURNS int
 LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE n int;
BEGIN
 IF p_from IS NULL OR p_to IS NULL OR p_from>p_to THEN RAISE EXCEPTION 'Invalid capture dates' USING ERRCODE='22023'; END IF;
 INSERT INTO public.user_activity_days AS d(user_id,activity_date,sources,first_seen_at,updated_at)
 SELECT a.user_id,(a.activity_at AT TIME ZONE 'America/Sao_Paulo')::date,array_agg(DISTINCT a.source ORDER BY a.source),min(a.activity_at),clock_timestamp()
 FROM public.analytics_live_activity(p_from::timestamp AT TIME ZONE 'America/Sao_Paulo',(p_to+1)::timestamp AT TIME ZONE 'America/Sao_Paulo') a
 WHERE a.user_id IS NOT NULL GROUP BY 1,2
 ON CONFLICT(user_id,activity_date) DO UPDATE SET sources=(SELECT array_agg(DISTINCT s ORDER BY s) FROM unnest(d.sources||excluded.sources) s),
 first_seen_at=least(d.first_seen_at,excluded.first_seen_at),updated_at=excluded.updated_at;
 GET DIAGNOSTICS n=ROW_COUNT;
 UPDATE public.analytics_instrumentation_coverage SET updated_at=clock_timestamp() WHERE source='activity_days';
 RETURN n;
END $$;

CREATE FUNCTION public.capture_conversion_match() RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE u uuid; pid uuid; opportunity text; path text; kind text; at_time timestamptz; m public.user_opportunity_matches%ROWTYPE; failure_code text;
BEGIN
 IF TG_TABLE_NAME='student_applications' THEN
  IF lower(NEW.status) NOT IN ('redirected','submitted') OR NEW.status IS NULL THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' THEN IF lower(OLD.status) IN ('redirected','submitted') THEN RETURN NEW; END IF; END IF;
  u:=NEW.user_id; opportunity:='partner_'||NEW.partner_id::text; kind:='application';
  path:=CASE WHEN lower(NEW.status)='redirected' THEN 'partner_redirected' ELSE 'partner_submitted' END;
  at_time:=clock_timestamp();
 ELSE
  IF NEW.event_type<>'redirect' OR NEW.entity_type<>'mec_opportunity' OR coalesce(NEW.source,'') LIKE 'legacy_%' THEN RETURN NEW; END IF;
  u:=NEW.user_id; opportunity:=coalesce(NEW.unified_opportunity_id,'mec_'||NEW.entity_id::text); kind:='redirect';path:='mec_redirect';at_time:=NEW.occurred_at;
 END IF;
 IF u IS NULL OR opportunity IS NULL OR at_time IS NULL THEN RETURN NEW; END IF;
 IF EXISTS(SELECT 1 FROM public.analytics_conversion_capture_failures f WHERE f.conversion_kind=kind AND f.conversion_id=NEW.id) THEN RETURN NEW; END IF;
 SELECT p.id INTO pid FROM public.user_profiles p WHERE p.id=u AND NOT coalesce(p.isdependent,false) AND p.parent_user_id IS NULL;
 IF pid IS NOT NULL THEN
  SELECT * INTO m FROM public.user_opportunity_matches x WHERE x.profile_id=pid AND x.unified_opportunity_id=opportunity
   AND x.generated_at<=at_time ORDER BY x.generated_at DESC,x.id LIMIT 1;
 END IF;
 INSERT INTO public.conversion_match_links(conversion_kind,conversion_id,user_id,profile_id,unified_opportunity_id,terminal_path,converted_at,match_id,match_score,match_generated_at,link_status)
 VALUES(kind,NEW.id,u,pid,opportunity,path,at_time,m.id,m.match_score,m.generated_at,
 CASE WHEN pid IS NULL THEN 'unresolved_profile' WHEN m.id IS NULL THEN 'no_prior_match' ELSE 'matched' END)
 ON CONFLICT(conversion_kind,conversion_id) DO NOTHING;
 RETURN NEW;
EXCEPTION WHEN OTHERS THEN
 -- No identifiers, payloads, SQLERRM or PII in warning. Missing snapshots remain observable by readers.
 failure_code:=SQLSTATE;
 BEGIN
  INSERT INTO public.analytics_conversion_capture_failures(conversion_kind,conversion_id,user_id,terminal_path,converted_at,sqlstate)
  VALUES(kind,NEW.id,u,path,at_time,failure_code) ON CONFLICT DO NOTHING;
 EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'analytics failure audit unavailable SQLSTATE=%',SQLSTATE;
 END;
 RAISE WARNING 'analytics conversion capture failed SQLSTATE=%',failure_code;
 RETURN NEW;
END $$;
CREATE TRIGGER tpd_application_conversion AFTER INSERT OR UPDATE OF status ON public.student_applications FOR EACH ROW EXECUTE FUNCTION public.capture_conversion_match();
-- engagement_events is the hottest write path: WHEN keeps card_view/card_click rows out of the function (and its EXCEPTION subtransaction).
CREATE TRIGGER tpd_mec_conversion AFTER INSERT ON public.engagement_events FOR EACH ROW
 WHEN (NEW.event_type='redirect' AND NEW.entity_type='mec_opportunity' AND NEW.user_id IS NOT NULL)
 EXECUTE FUNCTION public.capture_conversion_match();

INSERT INTO public.analytics_instrumentation_coverage(source,verified_since,capture_started_at,evidence_ref) VALUES
 ('application_terminal',clock_timestamp(),clock_timestamp(),'TP-D database trigger installation'),
 ('conversion_ledger',clock_timestamp(),clock_timestamp(),'TP-D database trigger installation'),
 ('activity_days',clock_timestamp(),clock_timestamp(),'TP-D daily capture installation'),
 ('mec_redirect',NULL,NULL,NULL),('click_surface',NULL,NULL,NULL);

CREATE FUNCTION public.analytics_source_coverage(p_source text,p_from timestamptz,p_to timestamptz) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.analytics_instrumentation_coverage%ROWTYPE; observed timestamptz; state text;
BEGIN
 SELECT * INTO c FROM public.analytics_instrumentation_coverage WHERE source=p_source;
 SELECT min(e.occurred_at) INTO observed FROM public.engagement_events e WHERE e.occurred_at<=now() AND
 ((p_source='mec_redirect' AND e.entity_type='mec_opportunity' AND e.event_type='redirect' AND coalesce(e.source,'') NOT LIKE 'legacy_%')
 OR (p_source='click_surface' AND e.event_type='card_click' AND e.source LIKE 'click:%'));
 state:=CASE WHEN c.verified_since IS NULL THEN 'unknown'
 WHEN least(coalesce(p_to,now()),now())<=c.verified_since THEN 'not_instrumented'
 WHEN p_from IS NULL OR p_from<c.verified_since THEN 'partial' ELSE 'instrumented' END;
 RETURN jsonb_build_object('verified_since',c.verified_since,'first_observed_at',observed,'capture_started_at',c.capture_started_at,
 'status',state,'partial',state='partial','reason',CASE WHEN state='unknown' THEN 'Sem recibo verificável de implantação' WHEN state='partial' THEN 'Janela cruza início verificado' ELSE NULL END);
END $$;

CREATE FUNCTION public.analytics_activity_coverage() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('capture_mode','daily_snapshot+live_union','granularity','day',
 'timezone','America/Sao_Paulo','capture_started_at',c.capture_started_at,'last_successful_capture_at',c.updated_at,
 'first_observed_by_source',(SELECT jsonb_object_agg(s.source,s.first_at) FROM
 (SELECT a.source,min(a.activity_at) first_at FROM public.analytics_live_activity(NULL,NULL) a GROUP BY a.source) s),
 'limitation','Sessões removidas entre coletas e dias sem evidência não são reconstruíveis; datas diárias BRT, sem precisão horária.')
 FROM public.analytics_instrumentation_coverage c WHERE source='activity_days'
 $$;
REVOKE ALL ON FUNCTION public.analytics_assert_period(timestamptz,timestamptz),public.analytics_assert_admin(),
 public.analytics_live_activity(timestamptz,timestamptz),public.active_user_ids(timestamptz,timestamptz),
 public.capture_user_activity_days(date,date),public.capture_conversion_match(),public.analytics_source_coverage(text,timestamptz,timestamptz),
 public.analytics_activity_period(timestamptz,timestamptz),public.analytics_activity_coverage() FROM PUBLIC,anon,authenticated,partner,service_role;
GRANT EXECUTE ON FUNCTION public.capture_user_activity_days(date,date) TO service_role;
-- Only real surviving evidence is consolidated, never interpolated session days.
SELECT public.capture_user_activity_days(
 coalesce((SELECT min((activity_at AT TIME ZONE 'America/Sao_Paulo')::date) FROM public.analytics_live_activity(NULL,NULL)),(now() AT TIME ZONE 'America/Sao_Paulo')::date),
 (now() AT TIME ZONE 'America/Sao_Paulo')::date);
SELECT cron.schedule('user-activity-days-daily','17 3 * * *',
 $$SELECT public.capture_user_activity_days((now() AT TIME ZONE 'America/Sao_Paulo')::date-2,(now() AT TIME ZONE 'America/Sao_Paulo')::date);$$);
