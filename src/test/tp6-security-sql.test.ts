// @vitest-environment node
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { beforeAll, afterAll, expect, it } from 'vitest';
let db: PGlite;
const id = (n: number) => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
beforeAll(async () => {
  db = new PGlite();
  await db.exec(`
    CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
    CREATE SCHEMA auth;
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$
      SELECT nullif(current_setting('test.uid',true),'')::uuid $$;
    CREATE TABLE auth.users(id uuid, email text);
    CREATE TABLE user_permissions(user_id uuid, permission text);
    CREATE FUNCTION is_backoffice_admin() RETURNS boolean LANGUAGE sql SECURITY DEFINER AS $$
      SELECT EXISTS(SELECT 1 FROM user_permissions WHERE user_id=auth.uid() AND permission='Controle de usuários') $$;
    CREATE TABLE courses(id uuid PRIMARY KEY);
    CREATE TABLE user_favorites(course_id uuid);
    CREATE TABLE user_profiles(id uuid PRIMARY KEY, full_name text);
    CREATE TABLE partner_opportunities(id uuid PRIMARY KEY, institution_id uuid);
    CREATE TABLE partners_users(user_id uuid,partner_id uuid);
    CREATE TABLE partner_forms(id uuid, partner_id uuid);
    CREATE TABLE student_applications(id uuid, user_id uuid,partner_id uuid,status text,
      answers jsonb,eligibility_results jsonb,created_at timestamptz, updated_at timestamptz);
    CREATE TABLE user_opportunity_matches(id uuid PRIMARY KEY,profile_id uuid,unified_opportunity_id text,
      match_score numeric,match_details jsonb);
    CREATE TABLE v_unified_opportunities(unified_id text,title text,provider_name text);
    CREATE TABLE learning_examples(id uuid, is_active boolean);
    ALTER TABLE learning_examples ENABLE ROW LEVEL SECURITY;
    CREATE POLICY "Service role can manage learning examples" ON learning_examples FOR ALL USING(true) WITH CHECK(true);
    CREATE POLICY "Everyone can read active examples" ON learning_examples FOR SELECT USING(is_active=true);
    CREATE VIEW vw_partner_application_details AS SELECT sa.id application_id,sa.partner_id,sa.user_id,
      up.full_name student_name,sa.status,sa.created_at,sa.updated_at,0::bigint total_answers_filled
      FROM student_applications sa JOIN user_profiles up ON up.id=sa.user_id;
    CREATE VIEW vw_partner_application_completion_buckets AS SELECT partner_id,'1. Até 25%'::text completion_bucket,
      count(*) applications_count FROM vw_partner_application_details GROUP BY partner_id;
    GRANT USAGE ON SCHEMA public,auth TO anon,authenticated;
    GRANT SELECT ON vw_partner_application_details,vw_partner_application_completion_buckets TO anon,authenticated;
    GRANT ALL ON learning_examples TO anon,authenticated;
    INSERT INTO auth.users VALUES ('${id(1)}','admin@example.test');
    INSERT INTO user_permissions VALUES ('${id(1)}','Controle de usuários');
    INSERT INTO user_profiles VALUES ('${id(5)}','Synthetic A'),('${id(6)}','Synthetic B');
    INSERT INTO partner_opportunities VALUES ('${id(10)}','${id(20)}'),('${id(11)}','${id(21)}');
    INSERT INTO partners_users VALUES ('${id(2)}','${id(20)}');
    INSERT INTO student_applications VALUES
      ('${id(30)}','${id(5)}','${id(10)}','SUBMITTED','{}','[{"met":true}]',now(),now()),
      ('${id(31)}','${id(6)}','${id(11)}','DRAFT','{}','[]',now(),now());
    INSERT INTO user_opportunity_matches
      SELECT gen_random_uuid(),'${id(5)}','course_'||n,50,'{"explanation":"synthetic"}'::jsonb FROM generate_series(1,25) n;
    INSERT INTO v_unified_opportunities SELECT 'course_'||n,'Course '||n,'Provider' FROM generate_series(1,25) n;
    INSERT INTO learning_examples VALUES ('${id(40)}',true),('${id(41)}',false);
  `);
}, 30000);
afterAll(async () => db?.close());
it('applies the actual forward migration', async () => {
  await db.exec(readFileSync(new URL('../../supabase/migrations/20261020210056_tp6_residual_security_and_contracts.sql', import.meta.url),'utf8'));
});
async function asUser(role: string, uid: string, sql: string) {
  await db.exec(`SET ROLE ${role}; SET test.uid='${uid}';`);
  try { return await db.query(sql); } finally { await db.exec('RESET ROLE; RESET test.uid;'); }
}
it('denies anonymous and ordinary accounts for both administrative RPCs', async () => {
  for (const [role,uid] of [['anon',''],['authenticated',id(3)],['authenticated',id(2)]]) {
    await expect(asUser(role,uid,'SELECT * FROM get_backoffice_users()')).rejects.toThrow();
    await expect(asUser(role,uid,`SELECT get_student_matches_admin('${id(5)}')`)).rejects.toThrow();
    await expect(asUser(role,uid,`SELECT get_student_matches_admin_page('${id(5)}',0,20)`)).rejects.toThrow();
  }
});
it('allows an admin to list users and fixes search_path and anon ACLs on every changed RPC', async () => {
  expect((await asUser('authenticated',id(1),'SELECT * FROM get_backoffice_users()')).rows).toHaveLength(1);
  const metadata = await db.query<{proconfig: string[]; anon: boolean}>(`
    SELECT proconfig,has_function_privilege('anon',p.oid,'execute') anon
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN
      ('get_backoffice_users','get_student_matches_admin','get_student_matches_admin_page','get_eligible_count_by_institution')
  `);
  expect(metadata.rows).toHaveLength(4);
  metadata.rows.forEach(row => { expect(row.anon).toBe(false); expect(row.proconfig.join()).toContain('search_path=public'); });
  await expect(asUser('authenticated',id(1),`SELECT get_student_matches_admin_page('${id(5)}',-1,20)`)).rejects.toThrow('paginação inválida');
  await expect(asUser('authenticated',id(1),`SELECT get_student_matches_admin_page('${id(5)}',0,101)`)).rejects.toThrow('paginação inválida');
});
it('keeps the old matches contract and supplies stable disjoint pages with details', async () => {
  const old = await asUser('authenticated',id(1),`SELECT get_student_matches_admin('${id(5)}') j`);
  expect((old.rows[0] as any).j.count).toBe(25);
  const a = await asUser('authenticated',id(1),`SELECT get_student_matches_admin_page('${id(5)}',0,20) j`);
  const b = await asUser('authenticated',id(1),`SELECT get_student_matches_admin_page('${id(5)}',1,20) j`);
  const first = (a.rows[0] as any).j, second = (b.rows[0] as any).j;
  expect(first.matches).toHaveLength(20); expect(second.matches).toHaveLength(5);
  expect(new Set([...first.matches,...second.matches].map(m=>m.unified_opportunity_id)).size).toBe(25);
  expect(first.matches[0].match_details).toEqual({ explanation: 'synthetic' });
  expect(first.matches[0].title).toMatch(/^Course /);
  expect((await asUser('authenticated',id(1),`SELECT get_student_matches_admin_page('${id(6)}',0,20) j`)).rows[0]).toMatchObject({j:{count:0,matches:[]}});
});
it('isolates both views while allowing the partner own institution', async () => {
  await expect(asUser('anon','','SELECT * FROM vw_partner_application_details')).rejects.toThrow();
  expect((await asUser('authenticated',id(3),'SELECT * FROM vw_partner_application_details')).rows).toHaveLength(0);
  const partner = await asUser('authenticated',id(2),'SELECT * FROM vw_partner_application_details');
  expect(partner.rows).toHaveLength(1);
  expect(partner.rows[0]).toMatchObject({ partner_id: id(10) });
  const buckets = await asUser('authenticated',id(2),'SELECT * FROM vw_partner_application_completion_buckets');
  expect(buckets.rows).toHaveLength(1);
  expect((await asUser('authenticated',id(1),'SELECT * FROM vw_partner_application_details')).rows).toHaveLength(2);
});
it('restores the eligible count with partner authorization and minimum ACL', async () => {
  expect((await asUser('authenticated',id(2),`SELECT get_eligible_count_by_institution('${id(20)}') n`)).rows[0]).toMatchObject({ n: 1 });
  await expect(asUser('authenticated',id(2),`SELECT get_eligible_count_by_institution('${id(21)}')`)).rejects.toThrow();
  await expect(asUser('anon','',`SELECT get_eligible_count_by_institution('${id(20)}')`)).rejects.toThrow();
});
it('prevents ordinary users from modifying agent examples and allows admins', async () => {
  await expect(asUser('anon','','INSERT INTO learning_examples VALUES (gen_random_uuid(),true)')).rejects.toThrow();
  await expect(asUser('authenticated',id(3),'INSERT INTO learning_examples VALUES (gen_random_uuid(),true)')).rejects.toThrow();
  expect((await asUser('authenticated',id(3),'SELECT * FROM learning_examples')).rows).toHaveLength(1);
  await asUser('authenticated',id(1),'INSERT INTO learning_examples VALUES (gen_random_uuid(),false)');
  expect((await asUser('authenticated',id(1),'SELECT * FROM learning_examples')).rows).toHaveLength(3);
});
