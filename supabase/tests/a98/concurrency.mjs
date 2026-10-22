import { spawn, execFileSync } from 'node:child_process';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

// Only accepts the unique disposable container created by replay.ps1.
const container=process.argv[2];
assert.match(container ?? '',/^supabase_db_nubo-a98-replay-[a-f0-9]{8}$/);
const uid='98000000-0000-4000-8000-000000000011';
const other='98000000-0000-4000-8000-000000000012';
const lit=v=>"'"+String(v).replaceAll("'","''")+"'";
const json=v=>lit(JSON.stringify(v))+'::jsonb';
const args=['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'];
function query(s){return execFileSync('docker',args,{input:s,encoding:'utf8',timeout:20000}).trim();}
const self=s=>`SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','${uid}',false); ${s}`;
function session(name){
 const child=spawn('docker',args,{stdio:['pipe','pipe','pipe'],windowsHide:true});
 let out='',err=''; const listeners=new Set();
 child.stdout.on('data',chunk=>{out+=chunk;for(const listener of listeners)listener();});
 child.stderr.on('data',chunk=>{err+=chunk;});
 const done=new Promise(resolve=>child.on('close',code=>resolve({code,out,err})));
 child.stdin.write(`SET application_name=${lit(name)};\n`);
 return {child,done,async send(s){
  const marker='a98_marker_'+Math.random().toString(16).slice(2);
  await new Promise((resolve,reject)=>{
   const timeout=setTimeout(()=>{listeners.delete(check);reject(new Error('SQL session marker timeout: '+err));},15000);
   function check(){if(out.includes(marker)){clearTimeout(timeout);listeners.delete(check);resolve();}}
   listeners.add(check); child.stdin.write(s+'\n\\echo '+marker+'\n');
  });
 },end(){child.stdin.end();}};
}
async function waitBlocked(name){
 const until=Date.now()+10000;
 while(Date.now()<until){
  if(query(`SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name=${lit(name)} AND wait_event_type='Lock')`)==='t')return;
  await new Promise(resolve=>setTimeout(resolve,50));
 }
 throw new Error('Expected observable lock wait: '+name);
}
const active=[];
try{
 // PostgreSQL17 records an administrative creator membership with SET/INHERIT
 // disabled. Assert no application role can assume the backend; fixture setup
 // invokes the actual private RPC as its owner, without granting runtime membership.
 assert.equal(query("SELECT bool_or(pg_has_role(r,'nubo_prefill_backend','USAGE') OR pg_has_role(r,'nubo_cursinho_worker','USAGE')) FROM unnest(ARRAY['anon','authenticated','service_role']) r"),'f');
 query(`INSERT INTO auth.users(id,phone,phone_confirmed_at) VALUES('${uid}','5511999999811',clock_timestamp()),('${other}','5511999999812',clock_timestamp());
 INSERT INTO public.user_profiles(id) VALUES('${uid}'),('${other}') ON CONFLICT(id) DO NOTHING;
 INSERT INTO cursinho_prefill.policy VALUES('cursinho_prefill','fixture-text','fixture-policy');
 INSERT INTO cursinho_prefill.origin_runtime VALUES('cursinho_prefill','fixture-preview','fixture-rule',true);
 INSERT INTO cursinho_prefill.origin_keys VALUES('fixture-key',decode(repeat('07',32),'hex'),clock_timestamp()-interval '1 hour',clock_timestamp()+interval '1 hour');
 INSERT INTO cursinho_sync.activation VALUES('admin_cursinho_resolution',true);`);
 const consent=(revision,action='grant')=>({action,purpose:'cursinho_prefill',requested_tiers:action==='grant'?['T1']:[],text_version:'fixture-text',policy_version:'fixture-policy',expected_consent_revision:revision});
 query(self(`SELECT public.record_consent_v1(${json(consent(0))});`));
 function makeBatch(id,op){
  const scope=JSON.parse(query(`SELECT cursinho_prefill.register_operation_v1('${uid}',${lit(op)},'fixture-key',600);`));
  const now=Number(query('SELECT floor(extract(epoch FROM clock_timestamp())*1000);'));const stamp=ms=>new Date(now+ms).toISOString();
  const c={field:'full_name',value:'Pessoa Sintética',candidate_id:'candidate-name',offer_version:'offer-'+id,checked_at:stamp(-500),partial:false,issued_at:stamp(-100),expires_at:stamp(300000)};
  const seg=['nubo-prefill-origin-v1',scope.environment_id,scope.contract_version,scope.kid,scope.user_id,scope.profile_id,scope.phone_version,scope.purpose,'i:'+scope.consent_revision,scope.text_version,scope.tiers.join(','),scope.policy_version,scope.rule_version,op,c.candidate_id,c.field,'s:'+c.value,'cursinho_nubo',c.offer_version,c.checked_at,'b:0',c.issued_at,c.expires_at];
  const bytes=Buffer.concat(seg.flatMap(s=>[Buffer.from(Buffer.byteLength(s).toString(16).padStart(8,'0')+':'),Buffer.from(s)]));
  const token='p1.fixture-key.'+createHmac('sha256',Buffer.alloc(32,7)).update(bytes).digest('base64url');
  return {commit_id:id,expected_profile_revision:Number(query(`SELECT prefill_revision FROM user_profiles WHERE id='${uid}'`)),operation_id:op,decisions:[{field:c.field,value:c.value,candidate_id:c.candidate_id,offer_version:c.offer_version,decision:'accepted',origin_proof:{checked_at:c.checked_at,partial:c.partial,issued_at:c.issued_at,expires_at:c.expires_at,token}}]};
 }
 // Revoke first: commit is blocked until revocation COMMIT, then MUST fail.
 const b1=makeBatch('revoke-first','op-revoke-first');
 const revoke=session('a98_revoke_first');active.push(revoke);
 await revoke.send('BEGIN; '+self(`SELECT public.record_consent_v1(${json(consent(1,'revoke'))});`));
 const pending=session('a98_commit_after_revoke');active.push(pending);
 pending.child.stdin.write(self(`SELECT public.commit_prefill_v1(${json(b1)});`)+'\n');pending.end();
 await waitBlocked('a98_commit_after_revoke');
 await revoke.send('COMMIT;');revoke.end();
 const denied=await pending.done;assert.notEqual(denied.code,0);assert.match(denied.err,/prefill_consent_required/);
 assert.equal(query(`SELECT count(*) FROM prefill_field_provenance WHERE profile_id='${uid}'`),'0');
 console.log('PASS revoke committed before acceptance: blocked waiter denied, zero provenance');
 // Commit first: revoke waits behind it; once revoke completes, even exact replay fails.
 query(self(`SELECT public.record_consent_v1(${json(consent(2))});`));
 const b2=makeBatch('commit-first','op-commit-first');
 const commit=session('a98_commit_first');active.push(commit);
 await commit.send('BEGIN; '+self(`SELECT public.commit_prefill_v1(${json(b2)});`));
 const later=session('a98_revoke_after_commit');active.push(later);
 later.child.stdin.write(self(`SELECT public.record_consent_v1(${json(consent(3,'revoke'))});`)+'\n');later.end();
 await waitBlocked('a98_revoke_after_commit');
 await commit.send('COMMIT;');commit.end();assert.equal((await later.done).code,0);
 assert.equal(query(`SELECT count(*) FROM prefill_field_provenance WHERE profile_id='${uid}'`),'1');
 assert.throws(()=>query(self(`SELECT public.commit_prefill_v1(${json(b2)});`)),/prefill_consent_required/);
 console.log('PASS acceptance committed first, revoke serialized, subsequent replay denied');
 // Identity change first: auth trigger/profile locking and validator see current phone.
 query(self(`SELECT public.record_consent_v1(${json(consent(4))});`));
 const b3=makeBatch('phone-first','op-phone-first');
 const phone=session('a98_phone_first');active.push(phone);
 await phone.send(`BEGIN; UPDATE auth.users SET phone='5511999999813' WHERE id='${uid}';`);
 const stale=session('a98_commit_after_phone');active.push(stale);
 stale.child.stdin.write(self(`SELECT public.commit_prefill_v1(${json(b3)});`)+'\n');stale.end();
 await waitBlocked('a98_commit_after_phone');await phone.send('COMMIT;');phone.end();
 const changed=await stale.done;assert.notEqual(changed.code,0);assert.match(changed.err,/prefill_consent_required|prefill_invalid_proof/);
 console.log('PASS phone change committed first: stale proof denied after observable lock wait');
 // Real permission guard: authenticated common/partner/self has no admin projection.
 assert.throws(()=>query(self(`SELECT cursinho_sync.read_resolution_v1('${uid}');`)),/cursinho_not_authorized/);
 query(`INSERT INTO public.user_permissions(user_id,permission) VALUES('${uid}','Controle de usuários');`);
 assert.match(query(self(`SELECT cursinho_sync.read_resolution_v1('${uid}');`)),/not_checked/);
 query(`DELETE FROM public.user_permissions WHERE user_id='${uid}';`);
 assert.throws(()=>query(self(`SELECT cursinho_sync.read_resolution_v1('${other}');`)),/cursinho_not_authorized/);
 console.log('PASS actual is_backoffice_admin/user_permissions: common/partner/self/other denied, permission owner allowed');
 // Two publishers contend on the same profile: both return the same receipt,
 // while history/item/run counter are committed exactly once.
 const lease=JSON.parse(query(`SELECT cursinho_sync.acquire_lease_v1('profile:${uid}','${uid}',60);`));
 const checkedAt=query(`SELECT to_char((clock_timestamp()-interval '1 second') AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');`);
 const publication={run_id:'concurrent-run',item_id:'same-item',profile_id:uid,phone_version:query(`SELECT cursinho_prefill.phone_version('${uid}');`),owner_id:uid,fence:lease.fence,revision:1,rule_version:'fixture-rule',resolution_state:'unique',official_situation:'aluno',checked_at:checkedAt,partial:false};
 const writer=session('a98_publisher_one');active.push(writer);
 await writer.send(`BEGIN; SELECT cursinho_sync.publish_v1(${json(publication)});`);
 const retry=session('a98_publisher_two');active.push(retry);
 retry.child.stdin.write(`SELECT cursinho_sync.publish_v1(${json(publication)});\n`);retry.end();
 await waitBlocked('a98_publisher_two');await writer.send('COMMIT;');writer.end();
 assert.equal((await retry.done).code,0);
 assert.equal(query("SELECT count(*) FROM cursinho_sync.resolution_history WHERE run_id='concurrent-run'"),'1');
 assert.equal(query("SELECT published_items FROM cursinho_sync.sync_runs WHERE run_id='concurrent-run'"),'1');
 const crashed=session('a98_publisher_rollback');active.push(crashed);
 await crashed.send(`BEGIN; SELECT cursinho_sync.publish_v1(${json({...publication,item_id:'crash-item',revision:2})}); ROLLBACK;`);crashed.end();
 assert.equal(query(`SELECT revision FROM cursinho_sync.current_resolution WHERE profile_id='${uid}'`),'1');
 assert.equal(query("SELECT count(*) FROM cursinho_sync.run_items WHERE item_id='crash-item'"),'0');
 query(`UPDATE cursinho_sync.leases SET expires_at=clock_timestamp()-interval '1 second' WHERE scope='profile:${uid}';`);
 const recovered=JSON.parse(query(`SELECT cursinho_sync.acquire_lease_v1('profile:${uid}','${other}',60);`));
 assert.equal(recovered.fence,2);
 assert.throws(()=>query(`SELECT cursinho_sync.publish_v1(${json({...publication,item_id:'late',revision:2})});`),/cursinho_lease_lost/);
 assert.equal(JSON.parse(query(`SELECT cursinho_sync.publish_v1(${json({...publication,owner_id:other,fence:2})});`)).revision,1);
 console.log('PASS two SQL publishers, identical replay, rollback, lease recovery and fenced late writer');
 // Public vector against full PostgreSQL, independent Node HMAC (not PGlite alone).
 const v=JSON.parse(readFileSync(new URL('./proof-vector.rc2.json',import.meta.url),'utf8'));
 assert.equal(query(`SELECT encode(cursinho_prefill.origin_bytes_v1(${json(v.scope)},${lit(v.operation_id)},${json(v.candidate)}),'hex');`),v.canonical_bytes_hex);
 assert.equal(query(`SELECT encode(cursinho_prefill.hmac_sha256_v1(decode(${lit(v.synthetic_key_hex)},'hex'),decode(${lit(v.canonical_bytes_hex)},'hex')),'hex');`),createHmac('sha256',Buffer.from(v.synthetic_key_hex,'hex')).update(Buffer.from(v.canonical_bytes_hex,'hex')).digest('hex'));
 console.log('A98_CONCURRENT_SQL_PASS');
}finally{
 for(const s of active){
  if(s.child.exitCode===null && !s.child.stdin.writableEnded)s.child.stdin.end('ROLLBACK;\n');
  await s.done;
 }
}
