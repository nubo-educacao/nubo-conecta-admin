// @vitest-environment node
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';

let db: PGlite;
const migration = new URL('../../supabase/migrations/20261009193000_command_center_opportunity_interest.sql', import.meta.url);
const partner = '11111111-1111-4111-8111-111111111111';
const mec = '22222222-2222-4222-8222-222222222222';
const period = ['2026-10-01T00:00:00Z', '2026-10-09T00:00:00Z'];
beforeAll(async () => {
  db = new PGlite();
  await db.exec(`
    CREATE ROLE authenticated; CREATE ROLE anon; CREATE ROLE partner IN ROLE authenticated;
    CREATE FUNCTION public.is_backoffice_admin() RETURNS boolean LANGUAGE sql AS
      $$ SELECT coalesce(current_setting('test.admin', true), '') = 'true' $$;
    CREATE TABLE institutions (id uuid PRIMARY KEY, name text);
    CREATE TABLE campus (id uuid PRIMARY KEY, institution_id uuid);
    CREATE TABLE courses (id uuid PRIMARY KEY, campus_id uuid, course_name text);
    CREATE TABLE opportunities (id uuid PRIMARY KEY, course_id uuid, opportunity_type text, year integer, semester text);
    CREATE TABLE partner_opportunities (id uuid PRIMARY KEY, institution_id uuid, name text);
    CREATE TABLE engagement_events (event_type text, entity_type text, entity_id uuid, unified_opportunity_id text, source text, event_count integer, occurred_at timestamptz);
    INSERT INTO institutions VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Instituto Real');
    INSERT INTO campus VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    INSERT INTO courses VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Medicina');
    INSERT INTO partner_opportunities VALUES ('${partner}','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Bolsa Real');
    INSERT INTO opportunities VALUES ('${mec}','cccccccc-cccc-4ccc-8ccc-cccccccccccc','sisu',2026,'2');
    INSERT INTO engagement_events VALUES
      ('card_click','partner_opportunity','${partner}',null,'card',3,'2026-10-02'),
      ('card_click','partner_opportunity',null,'partner_${partner}','card',4,'2026-10-03'),
      ('card_click','mec_opportunity','${mec}',null,'card',2,'2026-10-02'),
      ('card_click','mec_opportunity',null,'mec_${mec}','card',1,'2026-10-03'),
      ('card_click','partner_opportunity','${partner}',null,'legacy_partners_click_aggregate',100,'2026-10-02'),
      ('card_view','partner_opportunity','${partner}',null,'card',100,'2026-10-02'),
      ('redirect','partner_opportunity','${partner}',null,'card',100,'2026-10-02'),
      ('card_click','institution','${partner}',null,'card',100,'2026-10-02'),
      ('card_click','partner_opportunity','${partner}',null,'card',100,'2026-09-30'),
      ('card_click','partner_opportunity','${partner}',null,'card',100,'2026-10-09'),
      ('card_click','partner_opportunity',null,'bad_uuid','card',100,'2026-10-02'),
      ('card_click','partner_opportunity','dddddddd-dddd-4ddd-8ddd-dddddddddddd',null,'card',100,'2026-10-02');
  `);
  await db.exec(readFileSync(migration, 'utf8'));
  await db.exec("SET test.admin = 'true'");
}, 30000);
afterAll(async () => db?.close());
const ranking = () => db.query("SELECT * FROM public.get_command_center_opportunity_interest($1,$2,10)", period);
describe('opportunity interest SQL', () => {
  it('sums card clicks, resolves real titles/providers and excludes legacy, other events/entities and missing opportunities', async () => {
    expect((await ranking()).rows).toEqual([
      { opportunity_id: `partner_${partner}`, title: 'Bolsa Real', provider: 'Instituto Real', clicks: 7 },
      { opportunity_id: `mec_${mec}`, title: 'Medicina — SISU 2026/2', provider: 'Instituto Real', clicks: 3 },
    ]);
  });
  it('returns empty for periods without clicks', async () => {
    expect((await db.query("SELECT * FROM public.get_command_center_opportunity_interest('2027-01-01','2027-01-02',10)")).rows).toEqual([]);
  });
  it('rejects reversed periods', async () => {
    await expect(db.query("SELECT * FROM public.get_command_center_opportunity_interest('2027-01-02','2027-01-01',10)")).rejects.toMatchObject({ code: '22023' });
  });
  it('denies non-admins including the partner role inherited from authenticated', async () => {
    await db.exec("SET test.admin = 'false'; SET ROLE authenticated");
    await expect(ranking()).rejects.toMatchObject({ code: '42501' });
    await db.exec("RESET ROLE; SET test.admin = 'true'");
    const { rows } = await db.query("SELECT has_function_privilege('anon','public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer)','EXECUTE') AS anon, has_function_privilege('partner','public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer)','EXECUTE') AS partner");
    expect(rows).toEqual([{ anon: false, partner: true }]);
    await db.exec("SET test.admin = 'false'; SET ROLE partner");
    await expect(ranking()).rejects.toMatchObject({ code: '42501' });
    await db.exec("RESET ROLE; SET test.admin = 'true'");
  });
});
