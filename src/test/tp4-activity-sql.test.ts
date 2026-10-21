// @vitest-environment node
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { afterAll, beforeAll, expect, it } from 'vitest';
let db:PGlite;
const id=(n:number)=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
const migration=(name:string)=>readFileSync(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8');
beforeAll(async()=>{
  db=new PGlite();
  await db.exec(`
    CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
    CREATE SCHEMA auth;
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('test.uid',true),'')::uuid $$;
    CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql AS $$ SELECT current_setting('test.role',true) $$;
    CREATE FUNCTION is_backoffice_admin() RETURNS boolean LANGUAGE sql AS $$ SELECT coalesce(auth.uid()='${id(1)}'::uuid,false) $$;
    CREATE TABLE auth.users(id uuid,phone text);
    CREATE TABLE user_profiles(id uuid,full_name text,race text);
    CREATE TABLE user_income(user_id uuid,per_capita_income numeric);
    CREATE TABLE institutions(id uuid,name text);
    CREATE TABLE partner_opportunities(id uuid,institution_id uuid,name text);
    CREATE TABLE partners_users(user_id uuid,partner_id uuid);
    CREATE TABLE user_permissions(user_id uuid,permission text);
    CREATE TABLE student_applications(id uuid,user_id uuid,partner_id uuid,status text,answers jsonb,
      created_at timestamptz,eligibility_results jsonb,phase_id uuid);
    CREATE TABLE engagement_events(id uuid,user_id uuid,event_type text,occurred_at timestamptz,
      entity_type text,entity_id uuid,unified_opportunity_id text,destination_url text,event_count int,source text);
    GRANT USAGE ON SCHEMA public,auth TO anon,authenticated;
    INSERT INTO user_profiles VALUES ('${id(5)}','Synthetic A','test'),('${id(6)}','Synthetic B','test');
    INSERT INTO institutions VALUES ('${id(20)}','Institution A'),('${id(21)}','Institution B');
    INSERT INTO partner_opportunities VALUES ('${id(10)}','${id(20)}','Opportunity A'),('${id(11)}','${id(21)}','Opportunity B');
    INSERT INTO partners_users VALUES ('${id(2)}','${id(20)}');
    INSERT INTO student_applications
      SELECT ('00000000-0000-4000-8001-'||lpad(n::text,12,'0'))::uuid,'${id(5)}','${id(10)}','SUBMITTED','{}',
      '2026-10-01'::timestamptz,'[{"met":true}]',NULL FROM generate_series(1,25) n;
    INSERT INTO student_applications VALUES ('${id(30)}','${id(6)}','${id(11)}','DRAFT','{}','2026-10-01','[]',NULL);
    INSERT INTO engagement_events
      SELECT ('00000000-0000-4000-8002-'||lpad(n::text,12,'0'))::uuid,'${id(5)}','external_redirect',
      '2026-10-01','partner_opportunity','${id(10)}',NULL,NULL,1,'test' FROM generate_series(1,25) n;
    INSERT INTO engagement_events VALUES ('${id(31)}','${id(6)}','external_redirect','2026-10-01','partner_opportunity','${id(11)}',NULL,NULL,1,'test');
  `);
  // Apply canonical first-touch helpers and the exact existing applications RPC.
  const attribution=migration('20261015202330_tp7_first_touch_attribution_filters.sql');
  // Helpers are covered end-to-end by the existing TP7 SQL suite. This fixture
  // uses deterministic first-touch membership to exercise the preserved RPC.
  await db.exec(`
    CREATE FUNCTION assert_attribution_filter(uuid,uuid,boolean) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
    CREATE FUNCTION matches_first_touch_attribution(uid uuid,campaign uuid,channel uuid,unattributed boolean)
      RETURNS boolean LANGUAGE sql AS $$ SELECT campaign IS NULL OR uid='${id(5)}'::uuid $$;
  `);
  await db.exec(attribution.slice(attribution.indexOf('CREATE FUNCTION public.get_student_applications_with_details(')));
  const clicks=migration('20260812130000_engagement_events.sql');
  await db.exec(clicks.slice(clicks.indexOf('CREATE OR REPLACE FUNCTION public.get_student_clicks_admin(')));
  const partner=migration('20261016135200_guard_legacy_pii_rpcs.sql');
  const start=partner.indexOf('CREATE OR REPLACE FUNCTION public.get_partner_applications_by_institution(');
  const end=partner.indexOf('$function$;',start)+'$function$;'.length;
  await db.exec(partner.slice(start,end));
  await db.exec(`
    REVOKE ALL ON FUNCTION get_partner_applications_by_institution(uuid) FROM PUBLIC,anon;
    GRANT EXECUTE ON FUNCTION get_partner_applications_by_institution(uuid) TO authenticated;
  `);
},30000);
afterAll(async()=>db?.close());
async function asUser(role:string,uid:string,sql:string) {
  await db.exec(`SET ROLE ${role}; SET test.uid='${uid}'; SET test.role='${role}';`);
  try {return await db.query<any>(sql);} finally {await db.exec('RESET ROLE; RESET test.uid; RESET test.role;');}
}
it('allows admins and denies anonymous/ordinary/partner users on both admin activity RPCs',async()=>{
  for(const [role,uid] of [['anon',''],['authenticated',id(3)],['authenticated',id(2)]]) {
    await expect(asUser(role,uid,`SELECT * FROM get_student_applications_with_details()`)).rejects.toThrow();
    await expect(asUser(role,uid,`SELECT get_student_clicks_admin('${id(5)}',0,20)`)).rejects.toThrow();
  }
  expect((await asUser('authenticated',id(1),'SELECT * FROM get_student_applications_with_details()')).rows).toHaveLength(26);
});
it('paginates clicks without repeats or another student, including empty totals',async()=>{
  const a=(await asUser('authenticated',id(1),`SELECT get_student_clicks_admin('${id(5)}',0,20) j`)).rows[0].j;
  const b=(await asUser('authenticated',id(1),`SELECT get_student_clicks_admin('${id(5)}',1,20) j`)).rows[0].j;
  expect(a.count).toBe(25); expect(a.data).toHaveLength(20); expect(b.data).toHaveLength(5);
  expect(new Set([...a.data,...b.data].map(row=>row.id)).size).toBe(25);
  expect(a.data.every(row=>row.entity_name==='Opportunity A')).toBe(true);
  expect((await asUser('authenticated',id(1),`SELECT get_student_clicks_admin('${id(7)}',0,20) j`)).rows[0].j).toEqual({data:[],count:0});
});
it('preserves application data/eligibility and stable server-filtered pages per student',async()=>{
  const page=async(offset:number)=>(await asUser('authenticated',id(1),
    `SELECT id,user_id,eligibility_results FROM get_student_applications_with_details()
    WHERE user_id='${id(5)}' ORDER BY created_at DESC,id ASC LIMIT 20 OFFSET ${offset}`)).rows;
  const a=await page(0), b=await page(20);
  expect(a).toHaveLength(20);expect(b).toHaveLength(5);
  expect(new Set([...a,...b].map(row=>row.id)).size).toBe(25);
  expect([...a,...b].every(row=>row.user_id===id(5))).toBe(true);
  expect(a[0].eligibility_results).toEqual([{met:true}]);
  expect((await asUser('authenticated',id(1),`SELECT * FROM get_student_applications_with_details(NULL,'${id(50)}',NULL,NULL)`)).rows).toHaveLength(25);
});
it('keeps the legitimate partner endpoint scoped to its own institution',async()=>{
  expect((await asUser('authenticated',id(2),`SELECT * FROM get_partner_applications_by_institution('${id(20)}')`)).rows).toHaveLength(25);
  await expect(asUser('authenticated',id(2),`SELECT * FROM get_partner_applications_by_institution('${id(21)}')`)).rejects.toThrow();
  await expect(asUser('authenticated',id(3),`SELECT * FROM get_partner_applications_by_institution('${id(20)}')`)).rejects.toThrow();
});
