-- NUB-RD-99f / TP-D owner: execution 0f07e2b8-e8f9-474d-9106-a1ebbcd0a021.
-- RC2 urn:nubo:sprint9.2:contract:1.0.0-rc.2. No live policy/key is seeded.
-- Serial order: this foundation -> TP-A 98e/f (NEW migration) -> TP-C 81a.
BEGIN;
CREATE SCHEMA IF NOT EXISTS cursinho_prefill;
REVOKE ALL ON SCHEMA cursinho_prefill FROM PUBLIC, anon, authenticated;
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='nubo_prefill_backend') THEN
  CREATE ROLE nubo_prefill_backend NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
 END IF;
END $$;

ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS social_name text NULL;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS gender text NULL;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS prefill_revision bigint NOT NULL DEFAULT 0;
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.user_profiles'::regclass AND conname='user_profiles_prefill_gender_check') THEN
 ALTER TABLE public.user_profiles ADD CONSTRAINT user_profiles_prefill_gender_check CHECK
 (gender IS NULL OR gender IN ('mulher_cis','homem_cis','pessoa_nao_binaria','mulher_transgenero','homem_transgenero','prefiro_nao_declarar'));
 END IF;
END $$;

-- Private configuration. Intentionally EMPTY: policy/text publication and retention remain 98b gates.
CREATE TABLE IF NOT EXISTS cursinho_prefill.policy(
 purpose text PRIMARY KEY CHECK(purpose='cursinho_prefill'),
 text_version text NOT NULL CHECK(length(text_version)>0),
 policy_version text NOT NULL CHECK(length(policy_version)>0)
);
CREATE TABLE IF NOT EXISTS public.prefill_consent_events(
 event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 profile_id uuid NOT NULL REFERENCES public.user_profiles(id),
 purpose text NOT NULL CHECK(purpose='cursinho_prefill'),
 action text NOT NULL CHECK(action IN ('grant','decline','revoke')),
 effective_tiers text[] NOT NULL CHECK(effective_tiers IN (ARRAY[]::text[],ARRAY['T1'],ARRAY['T1','T2'])),
 consent_revision bigint NOT NULL CHECK(consent_revision>0),
 text_version text NOT NULL,
 policy_version text NOT NULL,
 phone_version text,
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(profile_id,purpose,consent_revision)
);
CREATE TABLE IF NOT EXISTS cursinho_prefill.consent_head(
 profile_id uuid PRIMARY KEY REFERENCES public.user_profiles(id),
 consent_revision bigint NOT NULL,
 event_id uuid NOT NULL REFERENCES public.prefill_consent_events(event_id)
);
CREATE TABLE IF NOT EXISTS public.prefill_field_decisions(
 profile_id uuid NOT NULL REFERENCES public.user_profiles(id),
 purpose text NOT NULL CHECK(purpose='cursinho_prefill'),
 field_key text NOT NULL CHECK(field_key IN ('full_name','social_name','birth_date','education','school_type','cpf','race','gender','family_count')),
 offer_version text NOT NULL CHECK(length(offer_version)>0),
 decision text NOT NULL CHECK(decision IN ('accepted','rejected','user_declared')),
 decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(profile_id,purpose,field_key,offer_version)
);
CREATE TABLE IF NOT EXISTS public.prefill_field_provenance(
 provenance_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 profile_id uuid NOT NULL REFERENCES public.user_profiles(id),
 purpose text NOT NULL CHECK(purpose='cursinho_prefill'),
 field_key text NOT NULL,
 offer_version text NOT NULL,
 commit_id text NOT NULL,
 operation_id text NOT NULL,
 candidate_id text NOT NULL,
 observation_id text NOT NULL,
 source text NOT NULL CHECK(source='cursinho_nubo'),
 rule_version text NOT NULL,
 policy_version text NOT NULL,
 consent_revision bigint NOT NULL,
 checked_at timestamptz NOT NULL,
 accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(profile_id,purpose,field_key,offer_version) REFERENCES public.prefill_field_decisions,
 UNIQUE(profile_id,commit_id,field_key)
);
-- Current attribution is separate from append-only offer/history records.
-- A later manual/legacy edit clears the current certificate without deleting accepted history.
CREATE TABLE IF NOT EXISTS public.prefill_field_state(
 profile_id uuid NOT NULL REFERENCES public.user_profiles(id),
 purpose text NOT NULL CHECK(purpose='cursinho_prefill'),
 field_key text NOT NULL CHECK(field_key IN ('full_name','social_name','birth_date','education','school_type','cpf','race','gender','family_count')),
 current_source text NOT NULL CHECK(current_source IN ('user_declared','cursinho_nubo')),
 provenance_id uuid REFERENCES public.prefill_field_provenance(provenance_id),
 PRIMARY KEY(profile_id,purpose,field_key),
 CHECK((current_source='cursinho_nubo')=(provenance_id IS NOT NULL))
);
ALTER TABLE public.prefill_field_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.prefill_field_state FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.prefill_field_state TO authenticated;
DROP POLICY IF EXISTS prefill_state_read ON public.prefill_field_state;
CREATE POLICY prefill_state_read ON public.prefill_field_state FOR SELECT TO authenticated
 USING (profile_id=(SELECT auth.uid()) OR (SELECT public.is_backoffice_admin()));
CREATE TABLE IF NOT EXISTS cursinho_prefill.commit_receipts(
 profile_id uuid NOT NULL REFERENCES public.user_profiles(id),
 commit_id text NOT NULL,
 request_hash bytea NOT NULL,
 receipt jsonb NOT NULL,
 PRIMARY KEY(profile_id,commit_id)
);
ALTER TABLE cursinho_prefill.policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE cursinho_prefill.consent_head ENABLE ROW LEVEL SECURITY;
ALTER TABLE cursinho_prefill.commit_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prefill_consent_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prefill_field_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prefill_field_provenance ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON cursinho_prefill.policy,cursinho_prefill.consent_head,cursinho_prefill.commit_receipts FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON public.prefill_consent_events,public.prefill_field_decisions,public.prefill_field_provenance FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.prefill_consent_events,public.prefill_field_decisions,public.prefill_field_provenance TO authenticated;
DROP POLICY IF EXISTS prefill_consent_read ON public.prefill_consent_events;
CREATE POLICY prefill_consent_read ON public.prefill_consent_events FOR SELECT TO authenticated
 USING (profile_id=(SELECT auth.uid()) OR (SELECT public.is_backoffice_admin()));
DROP POLICY IF EXISTS prefill_decision_read ON public.prefill_field_decisions;
CREATE POLICY prefill_decision_read ON public.prefill_field_decisions FOR SELECT TO authenticated
 USING (profile_id=(SELECT auth.uid()) OR (SELECT public.is_backoffice_admin()));
DROP POLICY IF EXISTS prefill_provenance_read ON public.prefill_field_provenance;
CREATE POLICY prefill_provenance_read ON public.prefill_field_provenance FOR SELECT TO authenticated
 USING (profile_id=(SELECT auth.uid()) OR (SELECT public.is_backoffice_admin()));

CREATE OR REPLACE FUNCTION cursinho_prefill.immutable_history() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN RAISE EXCEPTION 'prefill_history_is_append_only' USING ERRCODE='42501'; END $$;
DROP TRIGGER IF EXISTS prefill_consent_immutable ON public.prefill_consent_events;
CREATE TRIGGER prefill_consent_immutable BEFORE UPDATE OR DELETE ON public.prefill_consent_events
 FOR EACH ROW EXECUTE FUNCTION cursinho_prefill.immutable_history();
DROP TRIGGER IF EXISTS prefill_decision_immutable ON public.prefill_field_decisions;
CREATE TRIGGER prefill_decision_immutable BEFORE UPDATE OR DELETE ON public.prefill_field_decisions
 FOR EACH ROW EXECUTE FUNCTION cursinho_prefill.immutable_history();
DROP TRIGGER IF EXISTS prefill_provenance_immutable ON public.prefill_field_provenance;
CREATE TRIGGER prefill_provenance_immutable BEFORE UPDATE OR DELETE ON public.prefill_field_provenance
 FOR EACH ROW EXECUTE FUNCTION cursinho_prefill.immutable_history();

-- Revision detects legacy writes too; clients cannot reset it. Shared profile row lock
-- is also the serialization point for consent/revoke/commit. No network in transactions.
CREATE OR REPLACE FUNCTION cursinho_prefill.profile_revision() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE f text;
BEGIN
 IF TG_OP='UPDATE' THEN
  FOREACH f IN ARRAY ARRAY['full_name','social_name','birth_date','education','school_type','cpf','race','gender'] LOOP
   IF to_jsonb(NEW)->f IS DISTINCT FROM to_jsonb(OLD)->f THEN
    UPDATE public.prefill_field_state SET current_source='user_declared',provenance_id=NULL WHERE profile_id=NEW.id AND field_key=f;
   END IF;
  END LOOP;
 END IF;
 IF TG_OP='INSERT' THEN NEW.prefill_revision:=0;
 ELSE NEW.prefill_revision:=OLD.prefill_revision+1;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS prefill_profile_revision ON public.user_profiles;
CREATE TRIGGER prefill_profile_revision BEFORE INSERT OR UPDATE ON public.user_profiles
 FOR EACH ROW EXECUTE FUNCTION cursinho_prefill.profile_revision();
CREATE OR REPLACE FUNCTION cursinho_prefill.income_revision() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF TG_OP='DELETE' OR (TG_OP='UPDATE' AND (OLD.family_count IS DISTINCT FROM NEW.family_count OR OLD.user_id IS DISTINCT FROM NEW.user_id)) THEN
  UPDATE public.prefill_field_state SET current_source='user_declared',provenance_id=NULL WHERE profile_id=OLD.user_id AND field_key='family_count';
 END IF;
 UPDATE public.user_profiles SET prefill_revision=prefill_revision WHERE id=CASE WHEN TG_OP='DELETE' THEN OLD.user_id ELSE NEW.user_id END;
 IF TG_OP='UPDATE' AND OLD.user_id IS DISTINCT FROM NEW.user_id THEN
  UPDATE public.user_profiles SET prefill_revision=prefill_revision WHERE id=OLD.user_id;
 END IF;
 RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS prefill_income_revision ON public.user_income;
CREATE TRIGGER prefill_income_revision AFTER INSERT OR UPDATE OR DELETE ON public.user_income
 FOR EACH ROW EXECUTE FUNCTION cursinho_prefill.income_revision();

CREATE OR REPLACE FUNCTION cursinho_prefill.phone_version(p_profile uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT encode(sha256(convert_to(u.phone||':'||to_char(u.phone_confirmed_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US'),'UTF8')),'hex')
 FROM auth.users u WHERE u.id=p_profile AND u.phone IS NOT NULL AND u.phone_confirmed_at IS NOT NULL
$$;
CREATE OR REPLACE FUNCTION cursinho_prefill.lock_self() RETURNS public.user_profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'prefill_not_authorized' USING ERRCODE='42501'; END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid() FOR UPDATE;
 IF NOT FOUND OR coalesce(p.isdependent,false) OR p.parent_user_id IS NOT NULL OR p.current_dependent_id IS NOT NULL THEN
  RAISE EXCEPTION 'prefill_not_authorized' USING ERRCODE='42501';
 END IF;
 RETURN p;
END $$;

-- Extension points owned by 98f. No key or bypass flag; replace ONLY in a later migration.
-- adult_verified_v1 must validate source-derived adulthood against CURRENT server scope.
CREATE OR REPLACE FUNCTION cursinho_prefill.adult_verified_v1(p_profile uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path='' AS $$ SELECT false $$;
-- validate_origin_v1 must resolve private immutable operation metadata, validate MAC RC2,
-- current identity/phone/consent/text/tiers/policy/rule, age/offer/expiry/fencing, and return
-- {observation_id,rule_version,policy_version,consent_revision,checked_at,tier}.
-- It must never accept client metadata as proof, emit PII, perform network or grant public EXECUTE.
CREATE OR REPLACE FUNCTION cursinho_prefill.validate_origin_v1(p_profile uuid,p_operation text,p_decision jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN RAISE EXCEPTION 'prefill_external_acceptance_disabled' USING ERRCODE='42501'; END $$;

CREATE OR REPLACE FUNCTION public.read_prefill_consent_v1(p_profile uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE e public.prefill_consent_events; valid boolean;
BEGIN
 SELECT ev.* INTO e FROM cursinho_prefill.consent_head h JOIN public.prefill_consent_events ev ON ev.event_id=h.event_id WHERE h.profile_id=p_profile;
 valid:=e.action='grant' AND e.phone_version=cursinho_prefill.phone_version(p_profile)
 AND EXISTS(SELECT 1 FROM cursinho_prefill.policy c WHERE c.purpose=e.purpose AND c.text_version=e.text_version AND c.policy_version=e.policy_version)
 AND EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=p_profile AND NOT coalesce(p.isdependent,false) AND p.parent_user_id IS NULL AND p.current_dependent_id IS NULL)
 AND (NOT ('T2'=ANY(e.effective_tiers)) OR cursinho_prefill.adult_verified_v1(p_profile));
 RETURN jsonb_build_object('purpose','cursinho_prefill','consent_revision',coalesce(e.consent_revision,0),
 'effective_tiers',CASE WHEN coalesce(valid,false) THEN to_jsonb(e.effective_tiers) ELSE '[]'::jsonb END,
 'text_version',e.text_version,'policy_version',e.policy_version,'phone_version',cursinho_prefill.phone_version(p_profile),'recorded_at',e.recorded_at);
END $$;

CREATE OR REPLACE FUNCTION public.record_consent_v1(p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles; revision bigint; tiers text[]; e public.prefill_consent_events; phone text;
BEGIN
 IF jsonb_typeof(p_request) IS DISTINCT FROM 'object' OR
 (p_request-ARRAY['action','purpose','requested_tiers','text_version','policy_version','expected_consent_revision'])<>'{}'::jsonb OR
 NOT p_request ?& ARRAY['action','purpose','requested_tiers','text_version','policy_version','expected_consent_revision'] OR
 p_request->>'purpose' IS DISTINCT FROM 'cursinho_prefill' OR
 p_request->>'action' NOT IN ('grant','decline','revoke') OR jsonb_typeof(p_request->'action')<>'string' OR
 jsonb_typeof(p_request->'text_version')<>'string' OR length(p_request->>'text_version')=0 OR
 jsonb_typeof(p_request->'policy_version')<>'string' OR length(p_request->>'policy_version')=0 OR
 jsonb_typeof(p_request->'expected_consent_revision')<>'number' OR (p_request->>'expected_consent_revision') !~ '^[0-9]+$'
 THEN RAISE EXCEPTION 'prefill_invalid_request' USING ERRCODE='22023'; END IF;
 p:=cursinho_prefill.lock_self();
 SELECT h.consent_revision INTO revision FROM cursinho_prefill.consent_head h WHERE h.profile_id=p.id;
 IF coalesce(revision,0)<>(p_request->>'expected_consent_revision')::bigint THEN RAISE EXCEPTION 'prefill_consent_conflict' USING ERRCODE='40001'; END IF;
 phone:=cursinho_prefill.phone_version(p.id);
 IF p_request->>'action'='grant' THEN
  IF p_request->'requested_tiers' NOT IN ('["T1"]'::jsonb,'["T1","T2"]'::jsonb) OR phone IS NULL OR
   NOT EXISTS(SELECT 1 FROM cursinho_prefill.policy c WHERE c.purpose='cursinho_prefill' AND c.text_version=p_request->>'text_version' AND c.policy_version=p_request->>'policy_version')
   THEN RAISE EXCEPTION 'prefill_consent_unavailable' USING ERRCODE='42501'; END IF;
  tiers:=ARRAY(SELECT jsonb_array_elements_text(p_request->'requested_tiers'));
  IF 'T2'=ANY(tiers) AND NOT cursinho_prefill.adult_verified_v1(p.id) THEN RAISE EXCEPTION 'prefill_t2_unavailable' USING ERRCODE='42501'; END IF;
 ELSE
  IF p_request->'requested_tiers'<>'[]'::jsonb THEN RAISE EXCEPTION 'prefill_invalid_request' USING ERRCODE='22023'; END IF;
  tiers:=ARRAY[]::text[];
 END IF;
 INSERT INTO public.prefill_consent_events(profile_id,purpose,action,effective_tiers,consent_revision,text_version,policy_version,phone_version)
 VALUES(p.id,'cursinho_prefill',p_request->>'action',tiers,coalesce(revision,0)+1,p_request->>'text_version',p_request->>'policy_version',phone) RETURNING * INTO e;
 INSERT INTO cursinho_prefill.consent_head VALUES(p.id,e.consent_revision,e.event_id)
 ON CONFLICT(profile_id) DO UPDATE SET consent_revision=EXCLUDED.consent_revision,event_id=EXCLUDED.event_id;
 RETURN jsonb_build_object('event_id',e.event_id,'consent_revision',e.consent_revision,'purpose',e.purpose,'effective_tiers',e.effective_tiers,
 'text_version',e.text_version,'policy_version',e.policy_version,'recorded_at',e.recorded_at);
END $$;

-- Same validation for external and manual values. Null/absent never erases a field.
CREATE OR REPLACE FUNCTION cursinho_prefill.check_value(p_field text,p_value jsonb) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v text; d date; digits text; s integer; i integer; check_digit integer;
BEGIN
 v:=p_value#>>'{}';
 IF p_field='family_count' THEN
  IF jsonb_typeof(p_value) IS DISTINCT FROM 'number' OR v !~ '^[0-9]+$' OR v::numeric NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
  RETURN;
 END IF;
 IF jsonb_typeof(p_value) IS DISTINCT FROM 'string' OR length(btrim(v))=0 THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
 IF p_field IN ('full_name','social_name') THEN
  IF v ~ '[0-9]' THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
 ELSIF p_field='birth_date' THEN
  IF v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
  d:=v::date;
  IF d<'1930-01-01'::date OR d>CURRENT_DATE THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
 ELSIF p_field='education' THEN
  IF v NOT IN ('Ensino Fundamental','Ensino Médio Incompleto','Ensino Médio Completo','Ensino Superior Incompleto','Ensino Superior Completo','Pós-Gradução') THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
 ELSIF p_field='school_type' THEN
  IF v NOT IN ('Escola pública','Escola particular sem bolsa','Escola particular com bolsa 100%','Escola particular com bolsa parcial') THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
 ELSIF p_field='race' THEN
  IF v NOT IN ('Parda','Branca','Preta','Amarela','Indígena','Prefiro não informar') THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
 ELSIF p_field='gender' THEN
  IF v NOT IN ('mulher_cis','homem_cis','pessoa_nao_binaria','mulher_transgenero','homem_transgenero','prefiro_nao_declarar') THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
 ELSIF p_field='cpf' THEN
  IF v !~ '^[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}$' THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
  digits:=replace(replace(v,'.',''),'-','');
  IF digits=repeat(substr(digits,1,1),11) THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
  FOR check_digit IN 10..11 LOOP
   s:=0;
   FOR i IN 1..check_digit-1 LOOP s:=s+substr(digits,i,1)::integer*(check_digit+1-i); END LOOP;
   s:=(s*10)%11; IF s=10 THEN s:=0; END IF;
   IF s<>substr(digits,check_digit,1)::integer THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
  END LOOP;
 ELSE RAISE EXCEPTION 'prefill_invalid_field' USING ERRCODE='22023';
 END IF;
EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow OR numeric_value_out_of_range THEN
 RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023';
END $$;

CREATE OR REPLACE FUNCTION public.commit_prefill_v1(p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles; d jsonb; f text; kind text; patch jsonb:='{}'; metadata jsonb;
 verified jsonb:='{}'; consent jsonb; previous cursinho_prefill.commit_receipts;
 fingerprint bytea; accepted text[]:=ARRAY[]::text[]; rejected text[]:=ARRAY[]::text[];
 result jsonb; final_revision bigint; existing text; provenance uuid;
BEGIN
 IF jsonb_typeof(p_request) IS DISTINCT FROM 'object' OR
 (p_request-ARRAY['commit_id','expected_profile_revision','operation_id','decisions'])<>'{}'::jsonb OR
 NOT p_request ?& ARRAY['commit_id','expected_profile_revision','operation_id','decisions'] OR
 jsonb_typeof(p_request->'commit_id')<>'string' OR length(p_request->>'commit_id')=0 OR
 jsonb_typeof(p_request->'expected_profile_revision')<>'number' OR (p_request->>'expected_profile_revision') !~ '^[0-9]+$' OR
 jsonb_typeof(p_request->'operation_id') NOT IN ('string','null') OR p_request->>'operation_id'='' OR
 jsonb_typeof(p_request->'decisions')<>'array' OR jsonb_array_length(p_request->'decisions') NOT BETWEEN 1 AND 9
 THEN RAISE EXCEPTION 'prefill_invalid_request' USING ERRCODE='22023'; END IF;
 p:=cursinho_prefill.lock_self();
 IF (SELECT count(*)<>count(DISTINCT value->>'field') FROM jsonb_array_elements(p_request->'decisions')) THEN RAISE EXCEPTION 'prefill_duplicate_field' USING ERRCODE='22023'; END IF;
 -- Validate the WHOLE batch and all current proof scopes even on idempotent replay.
 FOR d IN SELECT value FROM jsonb_array_elements(p_request->'decisions') LOOP
  f:=d->>'field'; kind:=d->>'decision';
  IF jsonb_typeof(d)<>'object' OR (d-ARRAY['field','offer_version','decision','candidate_id','value','origin_proof'])<>'{}'::jsonb OR
   NOT d ?& ARRAY['field','offer_version','decision'] OR
   jsonb_typeof(d->'field')<>'string' OR f NOT IN ('full_name','social_name','birth_date','education','school_type','cpf','race','gender','family_count') OR
   jsonb_typeof(d->'offer_version')<>'string' OR length(d->>'offer_version')=0 OR
   jsonb_typeof(d->'decision')<>'string' OR kind NOT IN ('accepted','rejected','user_declared')
   THEN RAISE EXCEPTION 'prefill_invalid_decision' USING ERRCODE='22023'; END IF;
  IF kind='rejected' THEN
   IF d ?| ARRAY['value','origin_proof'] OR (d ? 'candidate_id' AND jsonb_typeof(d->'candidate_id') NOT IN ('string','null')) THEN RAISE EXCEPTION 'prefill_invalid_decision' USING ERRCODE='22023'; END IF;
   rejected:=array_append(rejected,f);
  ELSE
   PERFORM cursinho_prefill.check_value(f,d->'value');
   IF kind='user_declared' THEN
    IF d ?| ARRAY['candidate_id','origin_proof'] THEN RAISE EXCEPTION 'prefill_invalid_decision' USING ERRCODE='22023'; END IF;
   ELSE
    IF p_request->>'operation_id' IS NULL OR jsonb_typeof(d->'candidate_id') IS DISTINCT FROM 'string' OR length(d->>'candidate_id')=0 OR
     jsonb_typeof(d->'origin_proof') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
    consent:=public.read_prefill_consent_v1(p.id);
    IF NOT (consent->'effective_tiers' ? 'T1') THEN RAISE EXCEPTION 'prefill_consent_required' USING ERRCODE='42501'; END IF;
    metadata:=cursinho_prefill.validate_origin_v1(p.id,p_request->>'operation_id',d);
    IF metadata IS NULL OR NOT metadata ?& ARRAY['observation_id','rule_version','policy_version','consent_revision','checked_at','tier'] OR
      metadata->>'policy_version' IS DISTINCT FROM consent->>'policy_version' OR metadata->>'consent_revision' IS DISTINCT FROM consent->>'consent_revision' OR
      metadata->>'tier' IS DISTINCT FROM (CASE WHEN f IN ('cpf','race','gender','family_count') THEN 'T2' ELSE 'T1' END) OR
      NOT (consent->'effective_tiers' ? (metadata->>'tier')) THEN RAISE EXCEPTION 'prefill_invalid_proof' USING ERRCODE='42501'; END IF;
    SELECT decision INTO existing FROM public.prefill_field_decisions WHERE profile_id=p.id AND purpose='cursinho_prefill' AND field_key=f AND offer_version=d->>'offer_version';
    IF existing='rejected' THEN RAISE EXCEPTION 'prefill_offer_rejected' USING ERRCODE='42501'; END IF;
    verified:=verified||jsonb_build_object(f,metadata);
    accepted:=array_append(accepted,f);
   END IF;
   patch:=patch||jsonb_build_object(f,d->'value');
  END IF;
 END LOOP;
 fingerprint:=sha256(convert_to(p_request::text,'UTF8'));
 SELECT * INTO previous FROM cursinho_prefill.commit_receipts WHERE profile_id=p.id AND commit_id=p_request->>'commit_id';
 IF FOUND THEN
  IF previous.request_hash<>fingerprint THEN RAISE EXCEPTION 'prefill_commit_conflict' USING ERRCODE='40001'; END IF;
  RETURN previous.receipt;
 END IF;
 IF p.prefill_revision<>(p_request->>'expected_profile_revision')::bigint THEN RAISE EXCEPTION 'prefill_profile_conflict' USING ERRCODE='40001'; END IF;
 -- Serialize CPF assignments through this RPC (legacy writes remain outside this contract).
 IF patch ? 'cpf' THEN
  PERFORM pg_advisory_xact_lock(hashtextextended(patch->>'cpf',99));
  IF EXISTS(SELECT 1 FROM public.user_profiles up WHERE up.cpf=patch->>'cpf' AND up.id<>p.id) THEN RAISE EXCEPTION 'prefill_invalid_value' USING ERRCODE='22023'; END IF;
 END IF;
 IF patch-'family_count'<>'{}'::jsonb THEN
  UPDATE public.user_profiles SET
   full_name=coalesce(patch->>'full_name',full_name), social_name=coalesce(patch->>'social_name',social_name),
   birth_date=coalesce((patch->>'birth_date')::date,birth_date), education=coalesce(patch->>'education',education),
   school_type=coalesce(patch->>'school_type',school_type), cpf=coalesce(patch->>'cpf',cpf),
   race=coalesce(patch->>'race',race),gender=coalesce(patch->>'gender',gender) WHERE id=p.id;
 END IF;
 IF patch ? 'family_count' THEN
  INSERT INTO public.user_income(user_id,family_count) VALUES(p.id,(patch->>'family_count')::integer)
  ON CONFLICT(user_id) DO UPDATE SET family_count=EXCLUDED.family_count;
 END IF;
 FOR d IN SELECT value FROM jsonb_array_elements(p_request->'decisions') LOOP
  f:=d->>'field';
  INSERT INTO public.prefill_field_decisions(profile_id,purpose,field_key,offer_version,decision)
  VALUES(p.id,'cursinho_prefill',f,d->>'offer_version',d->>'decision') ON CONFLICT DO NOTHING;
  IF d->>'decision'='accepted' THEN
   metadata:=verified->f;
   INSERT INTO public.prefill_field_provenance(profile_id,purpose,field_key,offer_version,commit_id,operation_id,candidate_id,observation_id,source,rule_version,policy_version,consent_revision,checked_at)
   VALUES(p.id,'cursinho_prefill',f,d->>'offer_version',p_request->>'commit_id',p_request->>'operation_id',d->>'candidate_id',metadata->>'observation_id','cursinho_nubo',
    metadata->>'rule_version',metadata->>'policy_version',(metadata->>'consent_revision')::bigint,(metadata->>'checked_at')::timestamptz) RETURNING provenance_id INTO provenance;
  END IF;
  IF d->>'decision'<>'rejected' THEN
   INSERT INTO public.prefill_field_state(profile_id,purpose,field_key,current_source,provenance_id)
   VALUES(p.id,'cursinho_prefill',f,CASE WHEN d->>'decision'='accepted' THEN 'cursinho_nubo' ELSE 'user_declared' END,
     CASE WHEN d->>'decision'='accepted' THEN provenance ELSE NULL END)
   ON CONFLICT(profile_id,purpose,field_key) DO UPDATE SET current_source=EXCLUDED.current_source,provenance_id=EXCLUDED.provenance_id;
  END IF;
 END LOOP;
 -- A rejection-only commit also consumes a revision, so two competing batches cannot both win.
 IF patch='{}'::jsonb THEN UPDATE public.user_profiles SET prefill_revision=prefill_revision WHERE id=p.id; END IF;
 SELECT prefill_revision INTO final_revision FROM public.user_profiles WHERE id=p.id;
 result:=jsonb_build_object('commit_id',p_request->>'commit_id','profile_revision',final_revision,'committed_at',clock_timestamp(),'accepted_fields',accepted,'rejected_fields',rejected);
 INSERT INTO cursinho_prefill.commit_receipts VALUES(p.id,p_request->>'commit_id',fingerprint,result);
 RETURN result;
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cursinho_prefill FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.record_consent_v1(jsonb),public.commit_prefill_v1(jsonb),public.read_prefill_consent_v1(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.record_consent_v1(jsonb),public.commit_prefill_v1(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.read_prefill_consent_v1(uuid) TO nubo_prefill_backend;
-- No LOGIN/membership, emission RPC, key, live TTL/retention, source/network or policy activation.
COMMIT;
