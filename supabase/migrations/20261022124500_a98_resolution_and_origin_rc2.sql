-- TP-A 98e/98f, execution b854a826-6edb-4acd-b95a-8529585f05fb.
-- Requires immutable D99 foundation 20261022114108, reviewed HEAD 26a205ba.
-- NO policy, key, LOGIN/membership, source connection or activation is provisioned.
BEGIN;
CREATE SCHEMA IF NOT EXISTS cursinho_sync;
REVOKE ALL ON SCHEMA cursinho_sync FROM PUBLIC,anon,authenticated,service_role;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='nubo_cursinho_worker') THEN
  CREATE ROLE nubo_cursinho_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
 END IF;
END $$;

-- Separate administrative purpose: self consent is NEVER authority for batch.
CREATE TABLE IF NOT EXISTS cursinho_sync.activation(
 purpose text PRIMARY KEY CHECK(purpose='admin_cursinho_resolution'), enabled boolean NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS cursinho_sync.leases(
 scope text PRIMARY KEY CHECK(scope='batch' OR scope='source-session' OR scope ~ '^profile:[0-9a-f-]{36}$'),
 owner_id uuid NOT NULL, fence bigint NOT NULL CHECK(fence>0), expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS cursinho_sync.sync_runs(
 run_id text PRIMARY KEY CHECK(length(run_id) BETWEEN 1 AND 200),
 owner_id uuid NOT NULL, started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 published_items bigint NOT NULL DEFAULT 0 CHECK(published_items>=0)
);
CREATE TABLE IF NOT EXISTS cursinho_sync.current_resolution(
 profile_id uuid PRIMARY KEY REFERENCES public.user_profiles(id),
 phone_version text NOT NULL, revision bigint NOT NULL CHECK(revision>0),
 resolution_state text NOT NULL CHECK(resolution_state IN ('unique','not_found','ambiguous','invalid_phone','not_checked','error')),
 official_situation text CHECK(official_situation IN ('aluno','ex_aluno','processo_seletivo','aprovado_sem_matricula','rejeitado','indeterminada')),
 rule_version text NOT NULL CHECK(length(rule_version)>0), evidence_version text NOT NULL,
 checked_at timestamptz NOT NULL, last_attempt_at timestamptz NOT NULL,
 last_success_at timestamptz, last_success_summary jsonb,
 CHECK((resolution_state='unique')=(official_situation IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS cursinho_sync.resolution_history(
 run_id text NOT NULL REFERENCES cursinho_sync.sync_runs(run_id), item_id text NOT NULL,
 rule_version text NOT NULL, profile_id uuid NOT NULL REFERENCES public.user_profiles(id),
 phone_version text NOT NULL, revision bigint NOT NULL,
 observation jsonb NOT NULL, recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(run_id,item_id,rule_version), UNIQUE(profile_id,revision)
);
CREATE INDEX IF NOT EXISTS cursinho_history_profile_time ON cursinho_sync.resolution_history(profile_id,recorded_at DESC);
CREATE INDEX IF NOT EXISTS cursinho_current_selection ON cursinho_sync.current_resolution(resolution_state,last_attempt_at,profile_id);
CREATE TABLE IF NOT EXISTS cursinho_sync.run_items(
 run_id text NOT NULL, item_id text NOT NULL, rule_version text NOT NULL,
 request_hash bytea NOT NULL, receipt jsonb NOT NULL,
 PRIMARY KEY(run_id,item_id,rule_version),
 FOREIGN KEY(run_id,item_id,rule_version) REFERENCES cursinho_sync.resolution_history(run_id,item_id,rule_version)
);
CREATE TABLE IF NOT EXISTS cursinho_prefill.origin_runtime(
 purpose text PRIMARY KEY CHECK(purpose='cursinho_prefill'), environment_id text NOT NULL CHECK(length(environment_id)>0),
 rule_version text NOT NULL CHECK(length(rule_version)>0), enabled boolean NOT NULL DEFAULT false
);
-- A separate privileged provisioning gate owns keys. Neither worker nor self backend
-- has SELECT/INSERT/UPDATE on this table; no synthetic key is seeded by the migration.
CREATE TABLE IF NOT EXISTS cursinho_prefill.origin_keys(
 kid text PRIMARY KEY CHECK(kid ~ '^[A-Za-z0-9_-]{1,80}$'), secret bytea NOT NULL CHECK(octet_length(secret)=32),
 valid_from timestamptz NOT NULL, valid_until timestamptz NOT NULL CHECK(valid_until>valid_from)
);
CREATE TABLE IF NOT EXISTS cursinho_prefill.operation_records(
 operation_id text PRIMARY KEY CHECK(length(operation_id) BETWEEN 1 AND 200),
 profile_id uuid NOT NULL REFERENCES public.user_profiles(id), scope jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS cursinho_operation_expiry ON cursinho_prefill.operation_records(profile_id,expires_at);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['activation','leases','sync_runs','current_resolution','resolution_history','run_items'] LOOP
  EXECUTE format('ALTER TABLE cursinho_sync.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON cursinho_sync.%I FROM PUBLIC,anon,authenticated,service_role,nubo_cursinho_worker,nubo_prefill_backend',t);
 END LOOP;
 FOREACH t IN ARRAY ARRAY['origin_runtime','origin_keys','operation_records'] LOOP
  EXECUTE format('ALTER TABLE cursinho_prefill.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON cursinho_prefill.%I FROM PUBLIC,anon,authenticated,service_role,nubo_cursinho_worker,nubo_prefill_backend',t);
 END LOOP;
END $$;
DROP TRIGGER IF EXISTS cursinho_history_immutable ON cursinho_sync.resolution_history;
CREATE TRIGGER cursinho_history_immutable BEFORE UPDATE OR DELETE ON cursinho_sync.resolution_history FOR EACH ROW EXECUTE FUNCTION cursinho_prefill.immutable_history();
DROP TRIGGER IF EXISTS cursinho_item_immutable ON cursinho_sync.run_items;
CREATE TRIGGER cursinho_item_immutable BEFORE UPDATE OR DELETE ON cursinho_sync.run_items FOR EACH ROW EXECUTE FUNCTION cursinho_prefill.immutable_history();
DROP TRIGGER IF EXISTS cursinho_operation_immutable ON cursinho_prefill.operation_records;
CREATE TRIGGER cursinho_operation_immutable BEFORE UPDATE OR DELETE ON cursinho_prefill.operation_records FOR EACH ROW EXECUTE FUNCTION cursinho_prefill.immutable_history();

CREATE OR REPLACE FUNCTION cursinho_sync.require_activation_v1() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM 1 FROM cursinho_sync.activation WHERE purpose='admin_cursinho_resolution' AND enabled FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'cursinho_disabled' USING ERRCODE='42501'; END IF;
END $$;
-- Bounded acquisition never waits on an occupied lease row. New ownership ALWAYS
-- increments fence, even for the same owner. Renewing is a distinct fenced operation.
CREATE OR REPLACE FUNCTION cursinho_sync.acquire_lease_v1(p_scope text,p_owner uuid,p_seconds integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l cursinho_sync.leases; inserted boolean;
BEGIN
 PERFORM cursinho_sync.require_activation_v1();
 IF p_scope IS NULL OR p_owner IS NULL OR p_seconds IS NULL OR p_seconds NOT BETWEEN 1 AND 600 OR
  NOT(p_scope IN ('batch','source-session') OR p_scope ~ '^profile:[0-9a-f-]{36}$') THEN
  RAISE EXCEPTION 'cursinho_invalid_lease' USING ERRCODE='22023';
 END IF;
 IF NOT pg_try_advisory_xact_lock(hashtextextended(p_scope,98)) THEN RETURN '{"busy":true}'::jsonb; END IF;
 INSERT INTO cursinho_sync.leases(scope,owner_id,fence,expires_at)
 VALUES(p_scope,p_owner,1,clock_timestamp()+make_interval(secs=>p_seconds)) ON CONFLICT(scope) DO NOTHING RETURNING * INTO l;
 inserted:=FOUND;
 IF NOT inserted THEN
  SELECT * INTO l FROM cursinho_sync.leases WHERE scope=p_scope FOR UPDATE NOWAIT;
  IF l.expires_at>clock_timestamp() THEN RETURN '{"busy":true}'::jsonb; END IF;
  UPDATE cursinho_sync.leases SET owner_id=p_owner,fence=fence+1,expires_at=clock_timestamp()+make_interval(secs=>p_seconds)
   WHERE scope=p_scope RETURNING * INTO l;
 END IF;
 RETURN jsonb_build_object('fence',l.fence,'expires_at',l.expires_at);
EXCEPTION WHEN lock_not_available THEN RETURN '{"busy":true}'::jsonb;
END $$;
CREATE OR REPLACE FUNCTION cursinho_sync.renew_lease_v1(p_scope text,p_owner uuid,p_fence bigint,p_seconds integer) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM cursinho_sync.require_activation_v1();
 IF p_seconds IS NULL OR p_seconds NOT BETWEEN 1 AND 600 THEN RAISE EXCEPTION 'cursinho_invalid_lease' USING ERRCODE='22023'; END IF;
 IF NOT pg_try_advisory_xact_lock(hashtextextended(p_scope,98)) THEN RETURN false; END IF;
 PERFORM 1 FROM cursinho_sync.leases WHERE scope=p_scope FOR UPDATE NOWAIT;
 UPDATE cursinho_sync.leases SET expires_at=clock_timestamp()+make_interval(secs=>p_seconds)
 WHERE scope=p_scope AND owner_id=p_owner AND fence=p_fence AND expires_at>clock_timestamp();
 RETURN FOUND;
EXCEPTION WHEN lock_not_available THEN RETURN false;
END $$;

CREATE OR REPLACE FUNCTION cursinho_sync.publish_v1(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE profile uuid; l cursinho_sync.leases; old cursinho_sync.current_resolution;
 prior cursinho_sync.run_items; fingerprint bytea; receipt jsonb; checked timestamptz; success boolean;
BEGIN
 PERFORM cursinho_sync.require_activation_v1();
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['run_id','item_id','profile_id','phone_version','owner_id','fence','revision','rule_version','resolution_state','official_situation','checked_at','partial'] OR
  (p-ARRAY['run_id','item_id','profile_id','phone_version','owner_id','fence','revision','rule_version','resolution_state','official_situation','checked_at','partial'])<>'{}'::jsonb OR
  jsonb_typeof(p->'partial') IS DISTINCT FROM 'boolean' OR
  (p->>'fence') !~ '^[1-9][0-9]*$' OR (p->>'revision') !~ '^[1-9][0-9]*$' OR
  p->>'resolution_state' NOT IN ('unique','not_found','ambiguous','invalid_phone','not_checked','error') OR
  (p->>'resolution_state'='unique') IS DISTINCT FROM (p->>'official_situation' IS NOT NULL) OR
  length(p->>'item_id') NOT BETWEEN 1 AND 200 OR length(p->>'rule_version') NOT BETWEEN 1 AND 200 THEN
  RAISE EXCEPTION 'cursinho_invalid_publication' USING ERRCODE='22023';
 END IF;
 profile:=(p->>'profile_id')::uuid;
 -- Same lock order as self commit: profile, auth identity, configuration/lease.
 PERFORM 1 FROM public.user_profiles WHERE id=profile AND NOT coalesce(isdependent,false) AND parent_user_id IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'cursinho_invalid_profile' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM auth.users WHERE id=profile FOR SHARE;
 IF p->>'phone_version' IS DISTINCT FROM cursinho_prefill.phone_version(profile) OR p->>'phone_version' IS NULL THEN
  RAISE EXCEPTION 'cursinho_phone_changed' USING ERRCODE='40001';
 END IF;
 SELECT * INTO l FROM cursinho_sync.leases WHERE scope='profile:'||profile::text FOR UPDATE NOWAIT;
 IF NOT FOUND OR l.owner_id IS DISTINCT FROM (p->>'owner_id')::uuid OR l.fence IS DISTINCT FROM (p->>'fence')::bigint OR l.expires_at<=clock_timestamp() THEN
  RAISE EXCEPTION 'cursinho_lease_lost' USING ERRCODE='40001';
 END IF;
 -- Fencing is authorization for THIS attempt, not the semantic observation.
 -- A recovered valid owner may replay the same item under a newer fence.
 fingerprint:=sha256(convert_to((p-ARRAY['owner_id','fence'])::text,'UTF8'));
 SELECT * INTO prior FROM cursinho_sync.run_items WHERE run_id=p->>'run_id' AND item_id=p->>'item_id' AND rule_version=p->>'rule_version';
 IF FOUND THEN
  IF prior.request_hash<>fingerprint THEN RAISE EXCEPTION 'cursinho_replay_conflict' USING ERRCODE='40001'; END IF;
  RETURN prior.receipt;
 END IF;
 SELECT * INTO old FROM cursinho_sync.current_resolution WHERE profile_id=profile;
 IF (p->>'revision')::bigint<>coalesce(old.revision,0)+1 THEN RAISE EXCEPTION 'cursinho_revision_conflict' USING ERRCODE='40001'; END IF;
 checked:=(p->>'checked_at')::timestamptz;
 IF checked IS NULL OR checked>clock_timestamp() OR (old.phone_version=p->>'phone_version' AND checked<old.checked_at) THEN
  RAISE EXCEPTION 'cursinho_invalid_timestamp' USING ERRCODE='22023';
 END IF;
 success:=p->>'resolution_state' NOT IN ('error','not_checked') AND NOT (p->>'partial')::boolean;
 INSERT INTO cursinho_sync.sync_runs(run_id,owner_id) VALUES(p->>'run_id',(p->>'owner_id')::uuid) ON CONFLICT(run_id) DO NOTHING;
 IF NOT EXISTS(SELECT 1 FROM cursinho_sync.sync_runs WHERE run_id=p->>'run_id' AND owner_id=(p->>'owner_id')::uuid) THEN
  RAISE EXCEPTION 'cursinho_run_conflict' USING ERRCODE='40001';
 END IF;
 receipt:=jsonb_build_object('run_id',p->>'run_id','item_id',p->>'item_id','rule_version',p->>'rule_version','revision',(p->>'revision')::bigint);
 INSERT INTO cursinho_sync.resolution_history(run_id,item_id,rule_version,profile_id,phone_version,revision,observation)
 VALUES(p->>'run_id',p->>'item_id',p->>'rule_version',profile,p->>'phone_version',(p->>'revision')::bigint,p-ARRAY['owner_id','fence']);
 INSERT INTO cursinho_sync.current_resolution(profile_id,phone_version,revision,resolution_state,official_situation,rule_version,evidence_version,checked_at,last_attempt_at,last_success_at,last_success_summary)
 VALUES(profile,p->>'phone_version',(p->>'revision')::bigint,
  CASE WHEN (p->>'partial')::boolean THEN 'error' ELSE p->>'resolution_state' END,
  CASE WHEN NOT (p->>'partial')::boolean THEN p->>'official_situation' END,
  p->>'rule_version',(p->>'run_id')||':'||(p->>'item_id')||':'||(p->>'rule_version'),checked,clock_timestamp(),
  CASE WHEN success THEN checked WHEN old.phone_version=p->>'phone_version' THEN old.last_success_at END,
  CASE WHEN success AND p->>'resolution_state'='unique' THEN jsonb_build_object('official_situation',p->>'official_situation',
    'compatible_is_nubo_student',CASE WHEN p->>'official_situation' IN ('aluno','ex_aluno') THEN true WHEN p->>'official_situation' IN ('processo_seletivo','aprovado_sem_matricula','rejeitado') THEN false END,
    'checked_at',checked,'evidence_version',(p->>'run_id')||':'||(p->>'item_id')||':'||(p->>'rule_version'),'rule_version',p->>'rule_version')
   WHEN NOT success AND old.phone_version=p->>'phone_version' THEN old.last_success_summary END)
 ON CONFLICT(profile_id) DO UPDATE SET phone_version=EXCLUDED.phone_version,revision=EXCLUDED.revision,resolution_state=EXCLUDED.resolution_state,
  official_situation=EXCLUDED.official_situation,rule_version=EXCLUDED.rule_version,evidence_version=EXCLUDED.evidence_version,
  checked_at=EXCLUDED.checked_at,last_attempt_at=EXCLUDED.last_attempt_at,last_success_at=EXCLUDED.last_success_at,last_success_summary=EXCLUDED.last_success_summary;
 INSERT INTO cursinho_sync.run_items VALUES(p->>'run_id',p->>'item_id',p->>'rule_version',fingerprint,receipt);
 UPDATE cursinho_sync.sync_runs SET published_items=published_items+1 WHERE run_id=p->>'run_id';
 RETURN receipt;
END $$;
-- One row per profile, no joins multiplying applications. TP-C owns the public admin RPC.
-- Freshness/retention TTL is intentionally absent until approved; never label as fresh by fiat.
CREATE OR REPLACE FUNCTION cursinho_sync.read_resolution_v1(p_profile uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r cursinho_sync.current_resolution; changed boolean;
BEGIN
 IF NOT coalesce(public.is_backoffice_admin(),false) THEN
  RAISE EXCEPTION 'cursinho_not_authorized' USING ERRCODE='42501';
 END IF;
 SELECT * INTO r FROM cursinho_sync.current_resolution WHERE profile_id=p_profile;
 changed:=r.phone_version IS DISTINCT FROM cursinho_prefill.phone_version(p_profile);
 RETURN jsonb_build_object('contract_version','1.0.0-rc.2','resolution_state',CASE WHEN changed OR r.profile_id IS NULL THEN 'not_checked' ELSE r.resolution_state END,
 'reason',CASE WHEN changed AND r.profile_id IS NOT NULL THEN 'phone_changed' END,
 'official_situation',CASE WHEN NOT changed THEN r.official_situation END,
 'compatible_is_nubo_student',CASE WHEN NOT changed AND r.resolution_state='unique' THEN CASE
  WHEN r.official_situation IN ('aluno','ex_aluno') THEN true WHEN r.official_situation IN ('processo_seletivo','aprovado_sem_matricula','rejeitado') THEN false END END,
 'source_label','Cursinho Nubo','rule_version',coalesce(r.rule_version,'unconfigured'),'evidence_version',CASE WHEN NOT changed THEN r.evidence_version END,
 'checked_at',CASE WHEN NOT changed THEN r.checked_at END,'last_attempt_at',r.last_attempt_at,'last_success_at',CASE WHEN NOT changed THEN r.last_success_at END,
 'freshness','unknown','last_success_summary',CASE WHEN NOT changed THEN r.last_success_summary END);
END $$;

-- Pure RC2 encoder: EXACTLY 23 UTF-8, length-prefixed segments; no jsonb text MAC.
CREATE OR REPLACE FUNCTION cursinho_prefill.utc_stamp_v1(p text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE result text;
BEGIN
 IF p IS NULL OR p !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z$' THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 result:=to_char(p::timestamptz AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
 IF result<>(CASE WHEN length(p)=20 THEN replace(p,'Z','.000Z') ELSE p END) THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION cursinho_prefill.origin_bytes_v1(s jsonb,op text,c jsonb) RETURNS bytea
LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE parts text[]; v text; bytes bytea:=''::bytea; tiers text;
BEGIN
 IF s->'tiers' NOT IN ('["T1"]'::jsonb,'["T1","T2"]'::jsonb) OR
  (s->>'consent_revision') !~ '^[0-9]+$' OR (s->>'consent_revision')::numeric>9007199254740991 OR
  jsonb_typeof(c->'partial') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 IF jsonb_typeof(c->'value')='string' THEN v:='s:'||(c->>'value');
 ELSIF jsonb_typeof(c->'value')='number' AND c->>'value' ~ '^[0-9]+$' AND (c->>'value')::numeric<=9007199254740991 THEN v:='i:'||(c->>'value');
 ELSE RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 tiers:=CASE WHEN s->'tiers'='["T1"]'::jsonb THEN 'T1' ELSE 'T1,T2' END;
 parts:=ARRAY['nubo-prefill-origin-v1',s->>'environment_id',s->>'contract_version',s->>'kid',s->>'user_id',s->>'profile_id',s->>'phone_version',s->>'purpose',
  'i:'||(s->>'consent_revision'),s->>'text_version',tiers,s->>'policy_version',s->>'rule_version',op,c->>'candidate_id',c->>'field',v,'cursinho_nubo',c->>'offer_version',
  cursinho_prefill.utc_stamp_v1(c->>'checked_at'),CASE WHEN (c->>'partial')::boolean THEN 'b:1' ELSE 'b:0' END,
  cursinho_prefill.utc_stamp_v1(c->>'issued_at'),cursinho_prefill.utc_stamp_v1(c->>'expires_at')];
 FOREACH v IN ARRAY parts LOOP
  IF v IS NULL OR length(v)=0 THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
  bytes:=bytes||convert_to(lpad(to_hex(octet_length(convert_to(v,'UTF8'))),8,'0')||':','UTF8')||convert_to(v,'UTF8');
 END LOOP;
 RETURN bytes;
END $$;
-- RFC2104 HMAC-SHA256 using PostgreSQL core sha256 (no extension dependency).
-- The provisioning interface accepts exactly 32-byte keys. Kept private and tested
-- against Node crypto + the public RC2 vector; never exposed as a signing endpoint.
CREATE OR REPLACE FUNCTION cursinho_prefill.hmac_sha256_v1(k bytea,m bytea) RETURNS bytea
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path='' AS $$
DECLARE inner_pad bytea:=decode(repeat('36',64),'hex'); outer_pad bytea:=decode(repeat('5c',64),'hex'); i integer;
BEGIN
 IF octet_length(k)<>32 THEN RAISE EXCEPTION 'prefill_invalid_key' USING ERRCODE='42501'; END IF;
 FOR i IN 0..31 LOOP
  inner_pad:=set_byte(inner_pad,i,get_byte(k,i)#54); outer_pad:=set_byte(outer_pad,i,get_byte(k,i)#92);
 END LOOP;
 RETURN sha256(outer_pad||sha256(inner_pad||m));
END $$;
CREATE OR REPLACE FUNCTION cursinho_prefill.equal_mac_v1(a bytea,b bytea) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE difference integer:=0; i integer;
BEGIN
 IF a IS NULL OR b IS NULL OR octet_length(a)<>32 OR octet_length(b)<>32 THEN RETURN false; END IF;
 FOR i IN 0..31 LOOP difference:=difference|(get_byte(a,i)#get_byte(b,i)); END LOOP;
 RETURN difference=0;
END $$;
CREATE OR REPLACE FUNCTION cursinho_prefill.register_operation_v1(p_profile uuid,p_operation text,p_kid text,p_seconds integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE runtime cursinho_prefill.origin_runtime; consent jsonb; s jsonb; prior cursinho_prefill.operation_records;
BEGIN
 IF p_seconds IS NULL OR p_seconds NOT BETWEEN 1 AND 600 THEN RAISE EXCEPTION 'prefill_invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM public.user_profiles WHERE id=p_profile AND NOT coalesce(isdependent,false) AND parent_user_id IS NULL AND current_dependent_id IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'prefill_not_authorized' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM auth.users WHERE id=p_profile FOR SHARE;
 SELECT * INTO runtime FROM cursinho_prefill.origin_runtime WHERE purpose='cursinho_prefill' AND enabled FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'prefill_external_acceptance_disabled' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM cursinho_prefill.policy WHERE purpose='cursinho_prefill' FOR SHARE;
 PERFORM 1 FROM cursinho_prefill.origin_keys WHERE kid=p_kid AND valid_from<=clock_timestamp() AND valid_until>clock_timestamp()+make_interval(secs=>p_seconds) FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 consent:=public.read_prefill_consent_v1(p_profile);
 IF NOT(consent->'effective_tiers' ? 'T1') THEN RAISE EXCEPTION 'prefill_consent_required' USING ERRCODE='42501'; END IF;
 s:=jsonb_build_object('environment_id',runtime.environment_id,'contract_version','1.0.0-rc.2','kid',p_kid,
 'user_id',p_profile,'profile_id',p_profile,'phone_version',consent->>'phone_version','purpose','cursinho_prefill',
 'consent_revision',consent->'consent_revision','text_version',consent->>'text_version','tiers',consent->'effective_tiers','policy_version',consent->>'policy_version','rule_version',runtime.rule_version);
 SELECT * INTO prior FROM cursinho_prefill.operation_records WHERE operation_id=p_operation;
 IF FOUND THEN
  IF prior.profile_id<>p_profile OR prior.scope<>s OR prior.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'prefill_operation_conflict' USING ERRCODE='40001'; END IF;
  RETURN prior.scope;
 END IF;
 INSERT INTO cursinho_prefill.operation_records(operation_id,profile_id,scope,expires_at) VALUES(p_operation,p_profile,s,clock_timestamp()+make_interval(secs=>p_seconds));
 RETURN s;
END $$;
-- Extension point from 99f: authenticates echoed checked_at/partial/issued_at/
-- expires_at with exact field/value/offer/candidate and immutable SERVER scope.
-- Revoke and commit share the profile lock. Policy/key/runtime changes serialize
-- against FOR SHARE until the transaction commits. Replays run this validation too.
CREATE OR REPLACE FUNCTION cursinho_prefill.validate_origin_v1(p_profile uuid,p_operation text,p_decision jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE operation cursinho_prefill.operation_records; runtime cursinho_prefill.origin_runtime;
 consent jsonb; proof jsonb; s jsonb; c jsonb; k bytea; supplied bytea; expected bytea; token text;
 issued timestamptz; expires timestamptz; checked timestamptz; now_at timestamptz;
BEGIN
 PERFORM 1 FROM public.user_profiles WHERE id=p_profile AND NOT coalesce(isdependent,false) AND parent_user_id IS NULL AND current_dependent_id IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM auth.users WHERE id=p_profile FOR SHARE;
 SELECT * INTO runtime FROM cursinho_prefill.origin_runtime WHERE purpose='cursinho_prefill' AND enabled FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'prefill_external_acceptance_disabled' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM cursinho_prefill.policy WHERE purpose='cursinho_prefill' FOR SHARE;
 SELECT * INTO operation FROM cursinho_prefill.operation_records WHERE operation_id=p_operation AND profile_id=p_profile;
 IF NOT FOUND THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 s:=operation.scope; consent:=public.read_prefill_consent_v1(p_profile); now_at:=clock_timestamp();
 IF operation.expires_at<=now_at OR s->>'environment_id' IS DISTINCT FROM runtime.environment_id OR s->>'rule_version' IS DISTINCT FROM runtime.rule_version OR
  s->>'contract_version' IS DISTINCT FROM '1.0.0-rc.2' OR s->>'purpose' IS DISTINCT FROM 'cursinho_prefill' OR
  s->>'user_id' IS DISTINCT FROM p_profile::text OR s->>'profile_id' IS DISTINCT FROM p_profile::text OR
  s->>'phone_version' IS DISTINCT FROM consent->>'phone_version' OR s->>'consent_revision' IS DISTINCT FROM consent->>'consent_revision' OR
  s->>'text_version' IS DISTINCT FROM consent->>'text_version' OR s->>'policy_version' IS DISTINCT FROM consent->>'policy_version' OR
  s->'tiers' IS DISTINCT FROM consent->'effective_tiers' OR NOT (consent->'effective_tiers' ? 'T1') THEN
  RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501';
 END IF;
 proof:=p_decision->'origin_proof';
 IF jsonb_typeof(proof) IS DISTINCT FROM 'object' OR NOT proof ?& ARRAY['token','checked_at','partial','issued_at','expires_at'] OR
  (proof-ARRAY['token','checked_at','partial','issued_at','expires_at'])<>'{}'::jsonb OR jsonb_typeof(proof->'partial') IS DISTINCT FROM 'boolean' OR
  jsonb_typeof(proof->'token') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 token:=proof->>'token';
 IF token !~ ('^p1\.'||(s->>'kid')||'\.[A-Za-z0-9_-]{43}$') THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 issued:=cursinho_prefill.utc_stamp_v1(proof->>'issued_at')::timestamptz;
 expires:=cursinho_prefill.utc_stamp_v1(proof->>'expires_at')::timestamptz;
 checked:=cursinho_prefill.utc_stamp_v1(proof->>'checked_at')::timestamptz;
 IF checked>issued OR issued>now_at OR issued<operation.created_at-interval '1 second' OR expires<=now_at OR expires<=issued OR expires>operation.expires_at THEN
  RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501';
 END IF;
 SELECT secret INTO k FROM cursinho_prefill.origin_keys WHERE kid=s->>'kid' AND valid_from<=issued AND valid_until>=expires AND valid_until>now_at FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
 c:=(p_decision-ARRAY['decision','origin_proof'])||(proof-'token');
 expected:=cursinho_prefill.hmac_sha256_v1(k,cursinho_prefill.origin_bytes_v1(s,p_operation,c));
 supplied:=decode(translate(split_part(token,'.',3),'-_','+/')||'=','base64');
 -- Reject noncanonical base64 pad bits as well as incorrect MACs.
 IF translate(rtrim(encode(supplied,'base64'),'='),'+/','-_')<>split_part(token,'.',3) OR NOT cursinho_prefill.equal_mac_v1(expected,supplied) THEN
  RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501';
 END IF;
 RETURN jsonb_build_object('observation_id',p_operation||':'||(p_decision->>'candidate_id'),'rule_version',s->>'rule_version','policy_version',s->>'policy_version',
  'consent_revision',s->'consent_revision','checked_at',checked,'tier',CASE WHEN p_decision->>'field' IN ('cpf','race','gender','family_count') THEN 'T2' ELSE 'T1' END);
EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_parameter_value OR invalid_text_representation THEN
 RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501';
END $$;
-- adult_verified_v1 remains FALSE: 98p/source-age/identity policy is a separate gate.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cursinho_sync FROM PUBLIC,anon,authenticated,service_role,nubo_prefill_backend,nubo_cursinho_worker;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cursinho_prefill FROM PUBLIC,anon,authenticated,service_role,nubo_prefill_backend,nubo_cursinho_worker;
GRANT USAGE ON SCHEMA cursinho_sync TO nubo_cursinho_worker,authenticated;
GRANT EXECUTE ON FUNCTION cursinho_sync.acquire_lease_v1(text,uuid,integer),cursinho_sync.renew_lease_v1(text,uuid,bigint,integer),cursinho_sync.publish_v1(jsonb) TO nubo_cursinho_worker;
GRANT EXECUTE ON FUNCTION cursinho_sync.read_resolution_v1(uuid) TO authenticated;
GRANT USAGE ON SCHEMA cursinho_prefill TO nubo_prefill_backend;
GRANT EXECUTE ON FUNCTION cursinho_prefill.register_operation_v1(uuid,text,text,integer) TO nubo_prefill_backend;
-- All other foundation grants, including authenticated commit/consent, are preserved.
COMMIT;
