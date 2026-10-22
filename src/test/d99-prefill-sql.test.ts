// @vitest-environment node
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { beforeAll, afterAll, expect, it } from 'vitest';
let db: PGlite;
const uid='99000000-0000-4000-8000-000000000001';
const other='99000000-0000-4000-8000-000000000002';
const migration=()=>readFileSync('supabase/migrations/'+readdirSync('supabase/migrations').find(n=>n.endsWith('_d99_prefill_foundation.sql')),'utf8');
beforeAll(async()=>{
 db=new PGlite();
 await db.exec(`
 CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
 CREATE SCHEMA auth;
 CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('test.uid',true),'')::uuid $$;
 CREATE TABLE auth.users(id uuid PRIMARY KEY,phone text,phone_confirmed_at timestamptz);
 CREATE FUNCTION public.is_backoffice_admin() RETURNS boolean LANGUAGE sql AS $$ SELECT coalesce(current_setting('test.admin',true),'')='true' $$;
 CREATE TABLE public.user_profiles(id uuid PRIMARY KEY,full_name text,birth_date date,education text,school_type text,cpf varchar,race text,isdependent boolean DEFAULT false,parent_user_id uuid,current_dependent_id uuid);
 CREATE TABLE public.user_income(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id),family_count integer,member_incomes jsonb DEFAULT '[]',social_benefits numeric,alimony numeric,per_capita_income numeric);
 GRANT USAGE ON SCHEMA auth,public TO anon,authenticated;
 INSERT INTO auth.users VALUES ('${uid}','5511999990001',now()),('${other}','5511999990002',now());
 INSERT INTO user_profiles(id) VALUES ('${uid}'),('${other}');
 INSERT INTO user_income(user_id,family_count,member_incomes,social_benefits,alimony,per_capita_income) VALUES ('${uid}',2,'[1500,500]',100,50,1075);
 `);
},30000);
afterAll(async()=>db?.close());
async function call(fn:string,body:unknown,who=uid,role='authenticated'){
 await db.exec(`SET ROLE ${role}; SET test.uid='${who}';`);
 try{return (await db.query<{r:Record<string,unknown>}>(`SELECT public.${fn}($1::jsonb) r`,[JSON.stringify(body)])).rows[0].r;}
 finally{await db.exec('RESET ROLE; RESET test.uid;');}
}
const manual=(field:string,value:unknown)=>({field,value,offer_version:'manual-v1',decision:'user_declared'});
const batch=(id:string,revision:number,decisions:unknown[])=>({commit_id:id,expected_profile_revision:revision,operation_id:null,decisions});
const consent=(action='grant',rev=0,tiers=['T1'])=>({action,purpose:'cursinho_prefill',requested_tiers:tiers,text_version:'fixture-text',policy_version:'fixture-policy',expected_consent_revision:rev});
const revision=async()=>Number((await db.query<{r:number}>(`SELECT prefill_revision r FROM user_profiles WHERE id='${uid}'`)).rows[0].r);
it('replays the actual migration twice, with optional columns and a closed external gate',async()=>{
 await db.exec(migration()); await db.exec(migration());
 expect((await db.query(`SELECT social_name,gender FROM user_profiles WHERE id='${uid}'`)).rows[0]).toEqual({social_name:null,gender:null});
 await expect(call('commit_prefill_v1',batch('external-closed',0,[{field:'full_name',value:'Pessoa Sintética',decision:'accepted',offer_version:'v1',candidate_id:'c1',origin_proof:{token:'p1.fixture.'+'a'.repeat(43),checked_at:'2026-10-22T10:00:00Z',partial:false,issued_at:'2026-10-22T10:00:01Z',expires_at:'2099-10-22T10:05:01Z'}}]))).rejects.toThrow();
});
it('commits manual profile+income together and preserves every other income component',async()=>{
 const b=batch('manual-1',await revision(),[manual('social_name','Pessoa'),manual('gender','pessoa_nao_binaria'),manual('family_count',3)]);
 const r=await call('commit_prefill_v1',b);
 expect(r.accepted_fields).toEqual([]); expect(r.profile_revision).toBeGreaterThan(0);
 expect((await db.query(`SELECT family_count,member_incomes,social_benefits::int,alimony::int,per_capita_income::int FROM user_income WHERE user_id='${uid}'`)).rows[0]).toEqual({family_count:3,member_incomes:[1500,500],social_benefits:100,alimony:50,per_capita_income:1075});
 expect(await call('commit_prefill_v1',b)).toEqual(r);
 await expect(call('commit_prefill_v1',{...b,decisions:[manual('full_name','Outro')]})).rejects.toThrow();
});
it('rejects invalid batches before mutation, including duplicates, spoof and vocabulary',async()=>{
 const rev=await revision();
 for(const decisions of [[manual('social_name','Mudança'),manual('gender','invalid')],[manual('family_count',0)],[manual('family_count',21)],[manual('family_count',1.5)],[manual('cpf','111.111.111-11')],[manual('birth_date','2026-02-30')],[manual('education','qualquer')],[manual('full_name','x'),manual('full_name','y')],[{...manual('full_name','x'),candidate_id:'spoof'}]]){
  await expect(call('commit_prefill_v1',batch('invalid-'+JSON.stringify(decisions),rev,decisions))).rejects.toThrow();
 }
 await expect(call('commit_prefill_v1',{...batch('spoof',rev,[manual('full_name','x')]),profile_id:other})).rejects.toThrow();
 expect(await revision()).toBe(rev);
 expect((await db.query(`SELECT social_name FROM user_profiles WHERE id='${uid}'`)).rows[0]).toEqual({social_name:'Pessoa'});
});
it('detects edits from legacy profile and income paths; rejects stale revisions',async()=>{
 const rev=await revision(); await db.exec(`UPDATE user_profiles SET full_name='Edição legada' WHERE id='${uid}'`);
 await expect(call('commit_prefill_v1',batch('stale',rev,[manual('full_name','Perdido')]))).rejects.toThrow();
 const r=await revision(); await db.exec(`UPDATE user_income SET family_count=4 WHERE user_id='${uid}'`);
 expect(await revision()).toBeGreaterThan(r);
});
it('keeps consent closed without approved policy; decline/revoke work without lookup or live config',async()=>{
 await expect(call('record_consent_v1',consent())).rejects.toThrow();
 const d=await call('record_consent_v1',consent('decline',0,[]));
 expect(d.effective_tiers).toEqual([]); expect(d.consent_revision).toBe(1);
 const r=await call('record_consent_v1',consent('revoke',1,[])); expect(r.consent_revision).toBe(2);
 await expect(call('record_consent_v1',consent('grant',1))).rejects.toThrow();
 await db.exec(`INSERT INTO cursinho_prefill.policy(purpose,text_version,policy_version) VALUES ('cursinho_prefill','fixture-text','fixture-policy')`);
 const g=await call('record_consent_v1',consent('grant',2)); expect(g.effective_tiers).toEqual(['T1']);
 await expect(call('record_consent_v1',consent('grant',3,['T1','T2']))).rejects.toThrow();
 await expect(call('record_consent_v1',{...consent('grant',3),recorded_at:'2099-01-01'})).rejects.toThrow();
});
it('persists rejection by semantic offer across operations without rejected values or proof',async()=>{
 const b=batch('reject-1',await revision(),[{field:'full_name',offer_version:'offer-v1',decision:'rejected'}]);
 expect((await call('commit_prefill_v1',b)).rejected_fields).toEqual(['full_name']);
 expect((await db.query(`SELECT count(*)::int n FROM public.prefill_field_decisions WHERE profile_id='${uid}' AND offer_version='offer-v1'`)).rows[0]).toEqual({n:1});
 await expect(call('commit_prefill_v1',batch('reject-with-value',await revision(),[{field:'cpf',offer_version:'v1',decision:'rejected',value:'sensitive'}]))).rejects.toThrow();
});
it('enforces anon/other user/dependent/partner ACL, immutable history and private validator',async()=>{
 await expect(call('commit_prefill_v1',batch('anon',0,[manual('full_name','x')]),'', 'anon')).rejects.toThrow();
 await db.exec(`SET ROLE authenticated; SET test.uid='${other}';`);
 try{
  expect((await db.query('SELECT * FROM public.prefill_consent_events')).rows).toEqual([]);
  await expect(db.exec('DELETE FROM public.prefill_consent_events')).rejects.toThrow();
  await expect(db.exec('SELECT * FROM cursinho_prefill.policy')).rejects.toThrow();
 }finally{await db.exec('RESET ROLE; RESET test.uid;');}
 await db.exec(`UPDATE user_profiles SET current_dependent_id='${other}' WHERE id='${uid}'`);
 await expect(call('commit_prefill_v1',batch('dependent',await revision(),[manual('full_name','x')]))).rejects.toThrow();
 await db.exec(`UPDATE user_profiles SET current_dependent_id=null WHERE id='${uid}'`);
 const a=await db.query<{bad:boolean}>(`SELECT has_function_privilege('anon',p.oid,'execute') bad FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('cursinho_prefill') OR (n.nspname='public' AND p.proname IN ('record_consent_v1','commit_prefill_v1'))`);
 expect(a.rows.every(r=>!r.bad)).toBe(true);
});
it('returns no backend authority without membership, revalidates phone/policy on consent read',async()=>{
 await db.exec('SET ROLE service_role');
 try{await expect(db.exec(`SELECT public.read_prefill_consent_v1('${uid}')`)).rejects.toThrow();}finally{await db.exec('RESET ROLE');}
 await db.exec('SET ROLE nubo_prefill_backend');
 try{
  expect((await db.query<{r:Record<string,unknown>}>(`SELECT public.read_prefill_consent_v1('${uid}') r`)).rows[0].r.effective_tiers).toEqual(['T1']);
 }finally{await db.exec('RESET ROLE');}
 await db.exec(`UPDATE auth.users SET phone='5511999990003' WHERE id='${uid}'; SET ROLE nubo_prefill_backend`);
 try{expect((await db.query<{r:Record<string,unknown>}>(`SELECT public.read_prefill_consent_v1('${uid}') r`)).rows[0].r.effective_tiers).toEqual([]);}finally{await db.exec('RESET ROLE');}
});

it('keeps a valid T1 external acceptance denied until the 98f migration exists',async()=>{
 const scope=(await db.query<{r:Record<string,unknown>}>(`SELECT public.read_prefill_consent_v1('${uid}') r`)).rows[0].r;
 await call('record_consent_v1',consent('grant',Number(scope.consent_revision)));
 await expect(call('commit_prefill_v1',{...batch('closed-with-consent',await revision(),[{field:'full_name',value:'Pessoa Sintética',decision:'accepted',offer_version:'new-offer',candidate_id:'c1',origin_proof:{token:'p1.fixture.'+'a'.repeat(43)}}]),operation_id:'fixture-op'})).rejects.toThrow('prefill_external_acceptance_disabled');
});
it('uses a TEST-ONLY validator in disposable PostgreSQL to verify full batch rollback after a provenance write fails',async()=>{
 // This replacement is NOT part of any migration or runtime artifact. It proves transaction behavior only.
 await db.exec(`
 CREATE OR REPLACE FUNCTION cursinho_prefill.adult_verified_v1(p_profile uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path='' AS $$ SELECT true $$;
 CREATE OR REPLACE FUNCTION cursinho_prefill.validate_origin_v1(p_profile uuid,p_operation text,p_decision jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
 DECLARE c jsonb;
 BEGIN
  IF p_operation<>'fixture-operation' OR p_decision->'origin_proof'->>'token'<>'synthetic-only' THEN RAISE EXCEPTION 'synthetic_invalid'; END IF;
  c:=public.read_prefill_consent_v1(p_profile);
  RETURN jsonb_build_object('observation_id','fixture-observation','rule_version','fixture-rule','policy_version',c->>'policy_version','consent_revision',c->'consent_revision','checked_at','2026-10-22T10:00:00Z','tier',CASE WHEN p_decision->>'field'='family_count' THEN 'T2' ELSE 'T1' END);
 END $$;
 CREATE FUNCTION public.test_fail_provenance() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.field_key='family_count' THEN RAISE EXCEPTION 'synthetic_mid_batch_failure'; END IF; RETURN NEW; END $$;
 CREATE TRIGGER test_fail_provenance BEFORE INSERT ON public.prefill_field_provenance FOR EACH ROW EXECUTE FUNCTION public.test_fail_provenance();
 `);
 const scope=(await db.query<{r:Record<string,unknown>}>(`SELECT public.read_prefill_consent_v1('${uid}') r`)).rows[0].r;
 await call('record_consent_v1',consent('grant',Number(scope.consent_revision),['T1','T2']));
 const b={...batch('external-atomic',await revision(),[
 {field:'full_name',value:'Pessoa Sintética',decision:'accepted',offer_version:'atomic-v1',candidate_id:'c-name',origin_proof:{token:'synthetic-only'}},
 {field:'family_count',value:5,decision:'accepted',offer_version:'atomic-v1',candidate_id:'c-count',origin_proof:{token:'synthetic-only'}}]),operation_id:'fixture-operation'};
 const snapshot=async()=> (await db.query<{s:unknown}>(`SELECT jsonb_build_object('profile',(SELECT to_jsonb(p) FROM user_profiles p WHERE id='${uid}'),'income',(SELECT to_jsonb(i) FROM user_income i WHERE user_id='${uid}'),'decisions',(SELECT count(*) FROM prefill_field_decisions),'provenance',(SELECT count(*) FROM prefill_field_provenance),'receipts',(SELECT count(*) FROM cursinho_prefill.commit_receipts),'current_state',(SELECT coalesce(jsonb_agg(s),'[]'::jsonb) FROM prefill_field_state s)) s`)).rows[0].s;
 const before=await snapshot();
 await expect(call('commit_prefill_v1',b)).rejects.toThrow('synthetic_mid_batch_failure');
 expect(await snapshot()).toEqual(before);
 await db.exec('DROP TRIGGER test_fail_provenance ON public.prefill_field_provenance; DROP FUNCTION public.test_fail_provenance();');
 const receipt=await call('commit_prefill_v1',b);
 expect(receipt.accepted_fields).toEqual(['full_name','family_count']);
 expect((await db.query('SELECT field_key FROM prefill_field_provenance ORDER BY field_key')).rows).toEqual([{field_key:'family_count'},{field_key:'full_name'}]);
 expect(await call('commit_prefill_v1',b)).toEqual(receipt);
  const historyCount=await db.query('SELECT count(*)::int n FROM prefill_field_provenance');
 await call('commit_prefill_v1',batch('edited-source',await revision(),[manual('full_name','Pessoa Editada')]));
 expect((await db.query(`SELECT current_source,provenance_id FROM prefill_field_state WHERE profile_id='${uid}' AND field_key='full_name'`)).rows[0]).toEqual({current_source:'user_declared',provenance_id:null});
 expect(await db.query('SELECT count(*)::int n FROM prefill_field_provenance')).toEqual(historyCount);
 await db.exec(`UPDATE user_income SET family_count=6 WHERE user_id='${uid}'`);
 expect((await db.query(`SELECT current_source,provenance_id FROM prefill_field_state WHERE profile_id='${uid}' AND field_key='family_count'`)).rows[0]).toEqual({current_source:'user_declared',provenance_id:null});
 await call('commit_prefill_v1',batch('reject-accepted-offer',await revision(),[{field:'full_name',offer_version:'atomic-v1',decision:'rejected'}]));
 expect((await db.query(`SELECT EXISTS(SELECT 1 FROM prefill_field_decisions WHERE profile_id='${uid}' AND field_key='full_name' AND offer_version='atomic-v1' AND decision='rejected') denied`)).rows[0]).toEqual({denied:true});
 await expect(call('commit_prefill_v1',{...b,commit_id:'new-after-rejection',expected_profile_revision:await revision()})).rejects.toThrow('prefill_offer_rejected');
 const scope2=(await db.query<{r:Record<string,unknown>}>(`SELECT public.read_prefill_consent_v1('${uid}') r`)).rows[0].r;
 await call('record_consent_v1',consent('revoke',Number(scope2.consent_revision),[]));
 await expect(call('commit_prefill_v1',b)).rejects.toThrow('prefill_consent_required');
});
it('enforces append-only history even for the table owner and minimal function ACL/search_path',async()=>{
 for(const t of ['prefill_consent_events','prefill_field_decisions','prefill_field_provenance']){
  await expect(db.exec(`UPDATE public.${t} SET profile_id=profile_id`)).rejects.toThrow('prefill_history_is_append_only');
 }
 const funcs=await db.query<{proconfig:string[],anon:boolean,auth:boolean,nspname:string,proname:string}>(`SELECT proconfig,has_function_privilege('anon',p.oid,'EXECUTE') anon,has_function_privilege('authenticated',p.oid,'EXECUTE') auth,n.nspname,p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='cursinho_prefill' OR (n.nspname='public' AND p.proname IN ('record_consent_v1','commit_prefill_v1','read_prefill_consent_v1'))`);
 for(const f of funcs.rows){ expect(f.anon).toBe(false); expect(f.proconfig.join()).toContain('search_path='); if(f.nspname==='cursinho_prefill')expect(f.auth).toBe(false); }
});

it('replays all approved RC2 commit/consent payload fixtures against the real RPCs (synthetic scopes only)',async()=>{
 await db.exec(migration()); // restore the fail-closed implementation after the isolated test validator.
 const fixture=JSON.parse(readFileSync('supabase/tests/d99_prefill/fixtures.rc2.json','utf8'));
 for(const item of fixture.commit){
  const body={...item.payload,commit_id:'rc2-'+item.id,expected_profile_revision:await revision()};
  if(['rejected-without-value','user-declared'].includes(item.id)) expect(await call('commit_prefill_v1',body)).toHaveProperty('commit_id',body.commit_id);
  else await expect(call('commit_prefill_v1',body)).rejects.toThrow();
 }
 await db.exec("UPDATE cursinho_prefill.policy SET text_version='fixture-text-v1',policy_version='fixture-policy-v1'");
 for(const item of fixture.consent){
  const scope=(await db.query<{r:Record<string,unknown>}>(`SELECT public.read_prefill_consent_v1('${uid}') r`)).rows[0].r;
  const body={...item.payload,expected_consent_revision:Number(scope.consent_revision)};
  if(['grant-T1','decline','revoke'].includes(item.id)) expect(await call('record_consent_v1',body)).toHaveProperty('event_id');
  else await expect(call('record_consent_v1',body)).rejects.toThrow();
 }
});

it('D99-R1 saves manual race Outra without external certification and rejects unknown/manual-only external values',async()=>{
 const b=batch('manual-race-outra',await revision(),[manual('race','Outra')]);
 const r=await call('commit_prefill_v1',b);
 expect(r.accepted_fields).toEqual([]);
 expect((await db.query(`SELECT race FROM user_profiles WHERE id='${uid}'`)).rows[0]).toEqual({race:'Outra'});
 expect((await db.query(`SELECT current_source,provenance_id FROM prefill_field_state WHERE profile_id='${uid}' AND field_key='race'`)).rows[0]).toEqual({current_source:'user_declared',provenance_id:null});
 expect(await call('commit_prefill_v1',b)).toEqual(r);
 await expect(call('commit_prefill_v1',batch('manual-race-unknown',await revision(),[manual('race','Desconhecida')]))).rejects.toThrow('prefill_invalid_value');
 // The helper default remains the closed RC2 external vocabulary, even after 98f replaces the proof validator.
 await expect(db.query("SELECT cursinho_prefill.check_value('race',$1::jsonb)",[JSON.stringify('Outra')])).rejects.toThrow('prefill_invalid_value');
 await expect(call('commit_prefill_v1',{...batch('external-race-outra',await revision(),[{field:'race',offer_version:'external-v1',decision:'accepted',value:'Outra',candidate_id:'fixture-race',origin_proof:{token:'synthetic-only'}}]),operation_id:'fixture-operation'})).rejects.toThrow('prefill_invalid_value');
 expect((await db.query(`SELECT race FROM user_profiles WHERE id='${uid}'`)).rows[0]).toEqual({race:'Outra'});
});
