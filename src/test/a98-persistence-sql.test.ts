// @vitest-environment node
import { PGlite } from '@electric-sql/pglite';
import { createHmac } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { afterAll, beforeAll, expect, it } from 'vitest';

let db: PGlite;
const uid='98000000-0000-4000-8000-000000000001';
const other='98000000-0000-4000-8000-000000000002';
const owner='98000000-0000-4000-8000-000000000003';
const migration=(suffix:string)=>readFileSync('supabase/migrations/'+readdirSync('supabase/migrations').find(n=>n.endsWith(suffix)), 'utf8');
const sql=async<T=Record<string,unknown>>(s:string,values:unknown[]=[]) => (await db.query<T>(s,values)).rows;
async function asRole<T>(role:string,body:()=>Promise<T>,who=uid){
 await db.exec(`SET ROLE ${role}; SET test.uid='${who}';`);
 try{return await body();}finally{await db.exec('RESET ROLE; RESET test.uid;');}
}
const rpc=async(name:string,body:unknown)=>asRole('authenticated',async()=> (await sql<{r:Record<string,unknown>}>(`SELECT public.${name}($1::jsonb) r`,[JSON.stringify(body)]))[0].r);
const revision=async()=>Number((await sql<{n:number}>(`SELECT prefill_revision n FROM user_profiles WHERE id='${uid}'`))[0].n);
const phone=async()=> (await sql<{v:string}>(`SELECT cursinho_prefill.phone_version('${uid}') v`))[0].v;
const lease=async(scope='profile:'+uid,who=owner)=>asRole('nubo_cursinho_worker',async()=> (await sql<{r:Record<string,unknown>}>('SELECT cursinho_sync.acquire_lease_v1($1,$2::uuid,60) r',[scope,who]))[0].r);
const publish=async(request:unknown)=>asRole('nubo_cursinho_worker',async()=> (await sql<{r:Record<string,unknown>}>('SELECT cursinho_sync.publish_v1($1::jsonb) r',[JSON.stringify(request)]))[0].r);
const consent=async(action='grant',tiers=['T1'])=>{
 const c=(await sql<{r:Record<string,unknown>}>(`SELECT public.read_prefill_consent_v1('${uid}') r`))[0].r;
 return rpc('record_consent_v1',{action,purpose:'cursinho_prefill',requested_tiers:tiers,text_version:'fixture-text',policy_version:'fixture-policy',expected_consent_revision:Number(c.consent_revision)});
};
const batch=async(id:string,decisions:unknown[],operation='fixture-op')=>({commit_id:id,expected_profile_revision:await revision(),operation_id:operation,decisions});
function sign(scope:Record<string,unknown>,field='full_name',value:unknown='Pessoa Sintética',changes:Record<string,unknown>={}){
 const now=new Date(); const stamp=(ms:number)=>new Date(now.getTime()+ms).toISOString();
 const proof={checked_at:stamp(-1000),partial:false,issued_at:stamp(-500),expires_at:stamp(60000),...changes};
 const segments=['nubo-prefill-origin-v1',scope.environment_id,scope.contract_version,scope.kid,scope.user_id,scope.profile_id,scope.phone_version,scope.purpose,'i:'+scope.consent_revision,scope.text_version,(scope.tiers as string[]).join(','),scope.policy_version,scope.rule_version,'fixture-op','candidate-'+field,field,(typeof value==='number'?'i:':'s:')+value,'cursinho_nubo','offer-v1',proof.checked_at,'b:'+(proof.partial?1:0),proof.issued_at,proof.expires_at].map(String);
 const bytes=Buffer.concat(segments.flatMap(s=>[Buffer.from(Buffer.byteLength(s).toString(16).padStart(8,'0')+':'),Buffer.from(s)]));
 const token='p1.fixture-key.'+createHmac('sha256',Buffer.alloc(32,7)).update(bytes).digest('base64url');
 return {field,value,offer_version:'offer-v1',decision:'accepted',candidate_id:'candidate-'+field,origin_proof:{...proof,token}};
}
async function operation(){
 return asRole('nubo_prefill_backend',async()=> (await sql<{r:Record<string,unknown>}>(`SELECT cursinho_prefill.register_operation_v1('${uid}','fixture-op','fixture-key',120) r`))[0].r);
}
beforeAll(async()=>{
 db=new PGlite();
 await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
 CREATE SCHEMA auth;
 CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('test.uid',true),'')::uuid $$;
 CREATE FUNCTION public.is_backoffice_admin() RETURNS boolean LANGUAGE sql AS $$ SELECT coalesce(current_setting('test.admin',true),'')='true' $$;
 CREATE TABLE auth.users(id uuid PRIMARY KEY,phone text,phone_confirmed_at timestamptz);
 CREATE TABLE public.user_profiles(id uuid PRIMARY KEY,full_name text,birth_date date,education text,school_type text,cpf varchar,race text,isdependent boolean DEFAULT false,parent_user_id uuid,current_dependent_id uuid);
 CREATE TABLE public.user_income(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id),family_count integer,member_incomes jsonb DEFAULT '[]',social_benefits numeric,alimony numeric,per_capita_income numeric);
 GRANT USAGE ON SCHEMA public,auth TO anon,authenticated;
 INSERT INTO auth.users VALUES ('${uid}','5511999999801',clock_timestamp()),('${other}','5511999999802',clock_timestamp());
 INSERT INTO user_profiles(id) VALUES ('${uid}'),('${other}');
 INSERT INTO user_income(user_id,family_count,member_incomes) VALUES ('${uid}',2,'[1000,2000]');`);
 await db.exec(migration('_d99_prefill_foundation.sql'));
 await db.exec(migration('_a98_resolution_and_origin_rc2.sql'));
},30000);
afterAll(async()=>db?.close());

it('creates private RLS tables and no activation, key, membership or service-role authority',async()=>{
 expect(await sql(`SELECT count(*)::int n FROM cursinho_sync.activation`)).toEqual([{n:0}]);
 expect(await sql(`SELECT count(*)::int n FROM cursinho_prefill.origin_keys`)).toEqual([{n:0}]);
 for(const role of ['anon','authenticated','service_role']){
  await asRole(role,async()=>{
   await expect(sql('SELECT * FROM cursinho_sync.current_resolution')).rejects.toThrow();
   await expect(sql(`SELECT cursinho_sync.acquire_lease_v1('batch', '${owner}',60)`)).rejects.toThrow();
   await expect(sql('SELECT * FROM cursinho_prefill.origin_keys')).rejects.toThrow();
  });
 }
 const tables=await sql<{relrowsecurity:boolean}>(`SELECT c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='cursinho_sync' AND c.relkind='r'`);
 expect(tables.length).toBeGreaterThan(4); expect(tables.every(t=>t.relrowsecurity)).toBe(true);
 await expect(lease()).rejects.toThrow('cursinho_disabled');
});
it('enforces fencing, exact replay, atomic publication, monotonic revisions and last success',async()=>{
 await db.exec(`INSERT INTO cursinho_sync.activation VALUES ('admin_cursinho_resolution',true)`);
 const l=await lease(); expect(l.fence).toBe(1);
 expect(await lease('profile:'+uid,other)).toEqual({busy:true});
 const req={run_id:'run-one',item_id:'item-one',profile_id:uid,phone_version:await phone(),owner_id:owner,fence:l.fence,revision:1,rule_version:'rule-fixture',resolution_state:'unique',official_situation:'aluno',checked_at:new Date().toISOString(),partial:false};
 const result=await publish(req); expect(await publish(req)).toEqual(result);
 await expect(publish({...req,official_situation:'ex_aluno'})).rejects.toThrow('cursinho_replay_conflict');
 expect(await sql('SELECT count(*)::int n FROM cursinho_sync.resolution_history')).toEqual([{n:1}]);
 await expect(publish({...req,item_id:'new-item'})).rejects.toThrow('cursinho_revision_conflict');
 await expect(publish({...req,item_id:'invalid-date',revision:2,checked_at:'-infinity'})).rejects.toThrow();
 await db.exec(`CREATE FUNCTION public.a98_fail_item() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture_crash'; END $$;
 CREATE TRIGGER a98_fail_item BEFORE INSERT ON cursinho_sync.run_items FOR EACH ROW EXECUTE FUNCTION public.a98_fail_item();`);
 await expect(publish({...req,item_id:'crash',revision:2})).rejects.toThrow('fixture_crash');
 expect(await sql(`SELECT revision::int FROM cursinho_sync.current_resolution`)).toEqual([{revision:1}]);
 expect(await sql('SELECT count(*)::int n FROM cursinho_sync.resolution_history')).toEqual([{n:1}]);
 await db.exec('DROP TRIGGER a98_fail_item ON cursinho_sync.run_items; DROP FUNCTION public.a98_fail_item();');
 await publish({...req,item_id:'partial',revision:2,resolution_state:'error',official_situation:null,partial:true});
 await db.exec("SET test.admin='true'");
 const current=(await sql<{r:Record<string,unknown>}>(`SELECT cursinho_sync.read_resolution_v1('${uid}') r`))[0].r;
 expect(current.resolution_state).toBe('error'); expect(current.compatible_is_nubo_student).toBe(null);
 expect((current.last_success_summary as Record<string,unknown>).official_situation).toBe('aluno');
 expect(current.contract_version).toBe('1.0.0-rc.2'); expect(current.source_label).toBe('Cursinho Nubo'); expect(current.freshness).toBe('unknown');
 expect(Object.keys(current.last_success_summary as Record<string,unknown>).sort()).toEqual(['official_situation','compatible_is_nubo_student','checked_at','evidence_version','rule_version'].sort());
 await db.exec(`UPDATE cursinho_sync.leases SET expires_at=clock_timestamp()-interval '1 second'`);
 const second=await lease('profile:'+uid,other); expect(second.fence).toBe(2);
 await expect(publish({...req,item_id:'late',revision:3})).rejects.toThrow('cursinho_lease_lost');
 expect(await publish({...req,owner_id:other,fence:2})).toEqual(result);
 await db.exec(`UPDATE auth.users SET phone='5511999999803' WHERE id='${uid}'`);
 await expect(publish({...req,item_id:'changed',revision:3,owner_id:other,fence:2})).rejects.toThrow('cursinho_phone_changed');
 const changed=(await sql<{r:Record<string,unknown>}>(`SELECT cursinho_sync.read_resolution_v1('${uid}') r`))[0].r;
 expect(changed.resolution_state).toBe('not_checked'); expect(changed.reason).toBe('phone_changed');
 await db.exec('RESET test.admin');
 await asRole('authenticated',async()=>{await expect(sql(`SELECT cursinho_sync.read_resolution_v1('${other}')`)).rejects.toThrow();});
 await db.exec("SET test.admin='true'; SET ROLE authenticated;");
 expect((await sql<{r:Record<string,unknown>}>(`SELECT cursinho_sync.read_resolution_v1('${uid}') r`))[0].r.resolution_state).toBe('not_checked');
 await db.exec('RESET ROLE; RESET test.admin;');
});
it('matches the published RC2 byte vector and HMAC without persisting unaccepted values',async()=>{
 const vector=JSON.parse(readFileSync('supabase/tests/a98/proof-vector.rc2.json','utf8'));
 const r=await sql<{bytes:string,mac:string}>(`SELECT encode(cursinho_prefill.origin_bytes_v1($1::jsonb,$2,$3::jsonb),'hex') bytes, encode(cursinho_prefill.hmac_sha256_v1(decode($4,'hex'),cursinho_prefill.origin_bytes_v1($1::jsonb,$2,$3::jsonb)),'base64') mac`,[JSON.stringify(vector.scope),vector.operation_id,JSON.stringify(vector.candidate),vector.synthetic_key_hex]);
 expect(r[0].bytes).toBe(vector.canonical_bytes_hex); expect(Buffer.from(r[0].mac,'base64').toString('base64url')).toBe(vector.mac_base64url);
});
it('validates real MACs for multfield accepted/rejected/manual decisions and whole-batch rollback',async()=>{
 await db.exec(`INSERT INTO cursinho_prefill.policy VALUES ('cursinho_prefill','fixture-text','fixture-policy');
 INSERT INTO cursinho_prefill.origin_runtime VALUES ('cursinho_prefill','fixture-preview','rule-fixture',true);
 INSERT INTO cursinho_prefill.origin_keys VALUES ('fixture-key',decode(repeat('07',32),'hex'),clock_timestamp()-interval '1 minute',clock_timestamp()+interval '1 hour');`);
 await consent(); const scope=await operation();
 const signed=sign(scope); const body=await batch('accept-one',[signed,{field:'social_name',decision:'user_declared',value:'Pessoa Manual',offer_version:'manual-v1'},{field:'education',decision:'rejected',offer_version:'offer-v1'}]);
 const receipt=await rpc('commit_prefill_v1',body); expect(receipt.accepted_fields).toEqual(['full_name']);
 expect(await rpc('commit_prefill_v1',body)).toEqual(receipt);
 expect(await sql(`SELECT full_name,social_name FROM user_profiles WHERE id='${uid}'`)).toEqual([{full_name:'Pessoa Sintética',social_name:'Pessoa Manual'}]);
 for(const [field,value] of [['race','Outra'],['race','Desconhecida']]) await expect(rpc('commit_prefill_v1',await batch('vocab-'+value,[sign(scope,field,value)]))).rejects.toThrow('prefill_invalid_value');
 for(const key of ['checked_at','partial','issued_at','expires_at','token']){
  const modified=structuredClone(signed); Object.assign(modified.origin_proof,{[key]:key==='partial'?true:key==='token'?'p1.fixture-key.'+'A'.repeat(43):new Date(Date.now()+5000).toISOString()});
  await expect(rpc('commit_prefill_v1',await batch('tamper-'+key,[modified]))).rejects.toThrow();
 }
 const expired=sign(scope,'full_name','Pessoa Sintética',{expires_at:new Date(Date.now()-100).toISOString()});
 await expect(rpc('commit_prefill_v1',await batch('expired-valid-mac',[expired]))).rejects.toThrow('prefill_invalid_proof');
 await expect(rpc('commit_prefill_v1',await batch('duplicate',[signed,signed]))).rejects.toThrow('prefill_duplicate_field');
 const two=await batch('atomic',[sign(scope,'full_name','Outra Pessoa'),sign(scope,'birth_date','2000-01-01')]);
 const snapshot=async()=>sql(`SELECT jsonb_build_object('p',(SELECT to_jsonb(p) FROM user_profiles p WHERE id='${uid}'),'provenance',(SELECT count(*) FROM prefill_field_provenance),'decisions',(SELECT count(*) FROM prefill_field_decisions),'receipts',(SELECT count(*) FROM cursinho_prefill.commit_receipts)) r`);
 await db.exec(`CREATE FUNCTION public.a98_fail_provenance() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.field_key='birth_date' THEN RAISE EXCEPTION 'fixture_mid_commit'; END IF; RETURN NEW; END $$; CREATE TRIGGER a98_fail_provenance BEFORE INSERT ON public.prefill_field_provenance FOR EACH ROW EXECUTE FUNCTION public.a98_fail_provenance();`);
 const before=await snapshot(); await expect(rpc('commit_prefill_v1',two)).rejects.toThrow('fixture_mid_commit'); expect(await snapshot()).toEqual(before);
 await db.exec('DROP TRIGGER a98_fail_provenance ON prefill_field_provenance; DROP FUNCTION public.a98_fail_provenance();');
 expect((await rpc('commit_prefill_v1',two)).accepted_fields).toEqual(['full_name','birth_date']);
 await consent('revoke',[]); await expect(rpc('commit_prefill_v1',body)).rejects.toThrow('prefill_consent_required');
 await consent(); await expect(rpc('commit_prefill_v1',body)).rejects.toThrow('prefill_invalid_proof');
});

it('rejects all signed scope changes, expiry, key removal and dependent identity without accepting stale replay',async()=>{
 // A new operation under the current consent. The previous identifier is immutable.
 await expect(operation()).rejects.toThrow('prefill_operation_conflict');
 const registered=await asRole('nubo_prefill_backend',async()=> (await sql<{r:Record<string,unknown>}>(`SELECT cursinho_prefill.register_operation_v1('${uid}','scope-op','fixture-key',120) r`))[0].r);
 // Sign helper's operation is intentionally fixture-op; use the canonical encoder
 // to sign scope-op through Node crypto, never substitute a test SQL validator.
 const signed=sign(registered);
 const candidate={...signed,...signed.origin_proof};
 const bytes=(await sql<{v:string}>(`SELECT encode(cursinho_prefill.origin_bytes_v1($1::jsonb,'scope-op',$2::jsonb),'hex') v`,[JSON.stringify(registered),JSON.stringify(candidate)]))[0].v;
 signed.origin_proof.token='p1.fixture-key.'+createHmac('sha256',Buffer.alloc(32,7)).update(Buffer.from(bytes,'hex')).digest('base64url');
 const body=await batch('scope-commit',[signed],'scope-op');
 for(const [column,value] of [['environment_id','other-environment'],['rule_version','other-rule']]){
  const original=registered[column];
  await sql(`UPDATE cursinho_prefill.origin_runtime SET ${column}=$1`,[value]);
  await expect(rpc('commit_prefill_v1',body)).rejects.toThrow('prefill_invalid_proof');
  await sql(`UPDATE cursinho_prefill.origin_runtime SET ${column}=$1`,[original]);
 }
 await db.exec(`UPDATE cursinho_prefill.policy SET text_version='new-text'`);
 await expect(rpc('commit_prefill_v1',body)).rejects.toThrow('prefill_consent_required');
 await db.exec(`UPDATE cursinho_prefill.policy SET text_version='fixture-text'; UPDATE cursinho_prefill.origin_keys SET valid_until=clock_timestamp()-interval '1 second',valid_from=clock_timestamp()-interval '2 seconds'`);
 await expect(rpc('commit_prefill_v1',body)).rejects.toThrow('prefill_invalid_proof');
 await db.exec(`UPDATE cursinho_prefill.origin_keys SET valid_from=clock_timestamp()-interval '1 hour',valid_until=clock_timestamp()+interval '1 hour'; UPDATE user_profiles SET isdependent=true WHERE id='${uid}'`);
 await expect(rpc('commit_prefill_v1',body)).rejects.toThrow('prefill_not_authorized');
 await db.exec(`UPDATE user_profiles SET isdependent=false WHERE id='${uid}'`);
 body.expected_profile_revision=await revision();
 const receipt=await rpc('commit_prefill_v1',body); expect(await rpc('commit_prefill_v1',body)).toEqual(receipt);
 await db.exec(`UPDATE auth.users SET phone='5511999999804' WHERE id='${uid}'`);
 await expect(rpc('commit_prefill_v1',body)).rejects.toThrow('prefill_consent_required');
});

it('keeps global permits exclusive, renews only live fences and rejects malformed publications',async()=>{
 const first=await lease('batch'); expect(first.fence).toBe(1);
 expect(await lease('batch',other)).toEqual({busy:true});
 const renewed=await asRole('nubo_cursinho_worker',()=>sql<{r:boolean}>(`SELECT cursinho_sync.renew_lease_v1('batch','${owner}',1,60) r`));
 expect(renewed).toEqual([{r:true}]);
 expect(await asRole('nubo_cursinho_worker',()=>sql<{r:boolean}>(`SELECT cursinho_sync.renew_lease_v1('batch','${other}',1,60) r`))).toEqual([{r:false}]);
 const source=await lease('source-session'); expect(source.fence).toBe(1);
 expect(await lease('source-session',other)).toEqual({busy:true});
 await db.exec(`UPDATE cursinho_sync.leases SET expires_at=clock_timestamp()-interval '1 second' WHERE scope='batch'`);
 expect(await asRole('nubo_cursinho_worker',()=>sql<{r:boolean}>(`SELECT cursinho_sync.renew_lease_v1('batch','${owner}',1,60) r`))).toEqual([{r:false}]);
 expect((await lease('batch',other)).fence).toBe(2);
 for(const p of [{},{profile_id:uid,partial:null},{run_id:'x',phone:'forbidden'}])await expect(publish(p)).rejects.toThrow();
});

it('preserves ACL, fixed search paths and immutable observations after replaying the new migration',async()=>{
 await db.exec(migration('_a98_resolution_and_origin_rc2.sql'));
 const funcs=await sql<{anon:boolean,service:boolean,config:string[]}>(`SELECT has_function_privilege('anon',p.oid,'EXECUTE') anon,has_function_privilege('service_role',p.oid,'EXECUTE') service,proconfig config FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('cursinho_sync','cursinho_prefill')`);
 for(const f of funcs){expect(f.anon).toBe(false);expect(f.service).toBe(false);expect(f.config.join()).toContain('search_path=');}
 for(const t of ['cursinho_sync.resolution_history','cursinho_sync.run_items','cursinho_prefill.operation_records']) await expect(db.exec(`DELETE FROM ${t}`)).rejects.toThrow('prefill_history_is_append_only');
 expect(await sql(`SELECT count(*)::int n FROM pg_auth_members WHERE roleid IN (SELECT oid FROM pg_roles WHERE rolname IN ('nubo_cursinho_worker','nubo_prefill_backend'))`)).toEqual([{n:0}]);
});
