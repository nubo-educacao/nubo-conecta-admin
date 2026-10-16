// @vitest-environment node
// Filtros de campanha/divulgador (first-touch) no Command Center: executa a
// migration real num Postgres embutido, depois das definições anteriores das
// duas RPCs e dos helpers do TP-7. A bateria contra o schema real do DEV, com
// rollback, está em supabase/tests/command_center_attribution_filters/.
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';

const file = (name: string) => readFileSync(new URL(`../../supabase/migrations/${name}`, import.meta.url), 'utf8');
const NEW_MIGRATION = '20261016140000_command_center_attribution_filters.sql';

// Só o bloco dos helpers do TP-7 (o restante recria RPCs de Estudantes).
const tp7 = file('20261015202330_tp7_first_touch_attribution_filters.sql');
const tp7Helpers = tp7.slice(0, tp7.indexOf('-- ─── get_students_paginated'));

const id = (n: number) => `ccaf0000-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;
const A = 'ccaf0000-0000-4000-a000-00000000000a';
const B = 'ccaf0000-0000-4000-a000-00000000000b';
const X = 'ccaf0000-0000-4000-b000-00000000000e';
const Y = 'ccaf0000-0000-4000-b000-00000000000f';
const L = (n: number) => `ccaf0000-0000-4000-c000-00000000000${n}`;
const partner = '11111111-1111-4111-8111-111111111111';
const mec = '22222222-2222-4222-8222-222222222222';
const period = ['2026-10-01T00:00:00Z', '2026-10-09T00:00:00Z'];

let db: PGlite;
const baseline: Record<string, unknown> = {};

const interestSql = 'SELECT * FROM public.get_command_center_opportunity_interest($1,$2,10)';
const demographicsSql = 'SELECT public.get_command_center_demographics()::text AS t';

beforeAll(async () => {
  db = new PGlite();
  await db.exec(`
    CREATE ROLE authenticated; CREATE ROLE anon; CREATE ROLE service_role; CREATE ROLE partner IN ROLE authenticated;
    CREATE FUNCTION public.is_backoffice_admin() RETURNS boolean LANGUAGE sql AS
      $$ SELECT coalesce(current_setting('test.admin', true), '') = 'true' $$;

    CREATE TABLE channel_links (id uuid PRIMARY KEY, campaign_id uuid, channel_id uuid NOT NULL, archived_at timestamptz);
    CREATE TABLE user_attribution (user_id uuid PRIMARY KEY, first_touch_link_id uuid, last_touch_link_id uuid);

    CREATE TABLE institutions (id uuid PRIMARY KEY, name text);
    CREATE TABLE campus (id uuid PRIMARY KEY, institution_id uuid);
    CREATE TABLE courses (id uuid PRIMARY KEY, campus_id uuid, course_name text);
    CREATE TABLE opportunities (id uuid PRIMARY KEY, course_id uuid, opportunity_type text, year integer, semester text);
    CREATE TABLE partner_opportunities (id uuid PRIMARY KEY, institution_id uuid, name text);
    CREATE TABLE engagement_events (event_type text, entity_type text, entity_id uuid, unified_opportunity_id text,
      source text, event_count integer, occurred_at timestamptz, user_id uuid, anonymous_id text);

    CREATE TABLE user_profiles (id uuid PRIMARY KEY, parent_user_id uuid, education text, race text, school_type text);
    CREATE TABLE user_preferences (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid UNIQUE NOT NULL, workflow_data jsonb,
      match_status text, last_match_at timestamptz, family_income_per_capita numeric);
    CREATE TABLE user_income (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid UNIQUE NOT NULL, per_capita_income numeric);
    CREATE TABLE user_opportunity_matches (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), profile_id uuid NOT NULL,
      unified_opportunity_id text NOT NULL, generated_at timestamptz);
    CREATE TABLE chat_messages (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid, workflow text, created_at timestamptz);
    CREATE TABLE partner_forms (id uuid PRIMARY KEY, partner_id uuid NOT NULL, field_name text NOT NULL,
      question_text text NOT NULL, mapping_source text);
    CREATE TABLE student_applications (id uuid PRIMARY KEY, user_id uuid NOT NULL, partner_id uuid NOT NULL, status text NOT NULL,
      answers jsonb NOT NULL, created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL);

    -- Links: L1(A,X) L2(A,Y) L3(B,X) L4(sem campanha,Y) L5(A,X, arquivado)
    INSERT INTO channel_links VALUES
      ('${L(1)}', '${A}', '${X}', NULL), ('${L(2)}', '${A}', '${Y}', NULL), ('${L(3)}', '${B}', '${X}', NULL),
      ('${L(4)}', NULL, '${Y}', NULL), ('${L(5)}', '${A}', '${X}', '2026-09-01');
    -- U1 A,X · U2 first A,Y / last B · U3 B,X · U4 Y · U5 linha sem first · U6 sem linha · U7 link arquivado A,X
    INSERT INTO user_attribution VALUES
      ('${id(1)}', '${L(1)}', '${L(1)}'), ('${id(2)}', '${L(2)}', '${L(3)}'), ('${id(3)}', '${L(3)}', '${L(3)}'),
      ('${id(4)}', '${L(4)}', '${L(4)}'), ('${id(5)}', NULL, '${L(1)}'), ('${id(7)}', '${L(5)}', '${L(5)}');

    INSERT INTO institutions VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Instituto Real');
    INSERT INTO campus VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    INSERT INTO courses VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Medicina');
    INSERT INTO partner_opportunities VALUES ('${partner}','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Bolsa Real');
    INSERT INTO opportunities VALUES ('${mec}','cccccccc-cccc-4ccc-8ccc-cccccccccccc','sisu',2026,'2');
    INSERT INTO engagement_events VALUES
      ('card_click','partner_opportunity','${partner}',null,'card',3,'2026-10-02','${id(1)}',null),
      ('card_click','partner_opportunity',null,'partner_${partner}','card',2,'2026-10-03','${id(3)}',null),
      ('card_click','partner_opportunity','${partner}',null,'card',5,'2026-10-02',null,'anon-1'),
      ('card_click','partner_opportunity','${partner}',null,'card',1,'2026-10-04','${id(6)}',null),
      ('card_click','partner_opportunity','${partner}',null,'card',4,'2026-10-05','${id(2)}',null),
      ('card_click','partner_opportunity','${partner}',null,'card',1,'2026-10-05','${id(7)}',null),
      ('card_click','mec_opportunity','${mec}',null,'card',1,'2026-10-02','${id(2)}',null),
      ('card_click','mec_opportunity',null,'mec_${mec}','card',2,'2026-10-03',null,'anon-2'),
      ('card_click','partner_opportunity','${partner}',null,'legacy_partners_click_aggregate',100,'2026-10-02','${id(1)}',null),
      ('card_click','partner_opportunity','${partner}',null,'card',100,'2026-09-30','${id(1)}',null);

    INSERT INTO user_profiles (id) SELECT ('ccaf0000-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid FROM generate_series(1, 7) n;
    UPDATE user_profiles SET education = 'Ensino Médio Completo', race = 'Parda' WHERE id IN ('${id(1)}', '${id(3)}');
    UPDATE user_profiles SET education = 'Ensino Superior Completo' WHERE id = '${id(2)}';
    INSERT INTO user_opportunity_matches (profile_id, unified_opportunity_id, generated_at) VALUES ('${id(1)}', 'mec_x', '2026-08-01');
    INSERT INTO chat_messages (user_id, workflow, created_at) VALUES ('${id(3)}', 'match_workflow', '2026-01-20');
    INSERT INTO user_income (user_id, per_capita_income) VALUES ('${id(2)}', 800);
  `);
  await db.exec(tp7Helpers);
  await db.exec(file('20261009203000_command_center_opportunity_interest.sql'));
  await db.exec(file('20261015204255_command_center_match_demographics_views.sql'));
  await db.exec("SET test.admin = 'true'");

  // Baseline com as assinaturas antigas, antes da migration nova.
  baseline.interest = (await db.query(interestSql, period)).rows;
  baseline.demographics = (await db.query<{ t: string }>(demographicsSql)).rows[0].t;

  await db.exec(file(NEW_MIGRATION));
}, 30000);
afterAll(async () => db?.close());

const interest = async (campaign: string | null = null, channel: string | null = null, unattributed: boolean | null = null) =>
  (await db.query<{ opportunity_id: string; clicks: number }>(
    `SELECT opportunity_id, clicks FROM public.get_command_center_opportunity_interest(
       p_from => $1, p_to => $2, p_limit => 10,
       p_filter_campaign_id => $3, p_filter_channel_id => $4, p_filter_unattributed => $5)`,
    [...period, campaign, channel, unattributed])).rows.map((r) => `${r.opportunity_id.split('_')[0]}:${r.clicks}`);

type Demo = { match_health: Record<string, number>; education: { label: string; value: number }[];
  income: { value: number }[]; race: { value: number }[]; school_type: { value: number }[] };
const demographics = async (campaign: string | null = null, channel: string | null = null, unattributed: boolean | null = null) =>
  (await db.query<{ j: Demo }>(
    `SELECT public.get_command_center_demographics(
       p_filter_campaign_id => $1, p_filter_channel_id => $2, p_filter_unattributed => $3)::jsonb AS j`,
    [campaign, channel, unattributed])).rows[0].j;

describe('baseline preservado (filtros nulos)', () => {
  it('opportunity interest: mesmas linhas, contagens e ordem da função anterior', async () => {
    expect((await db.query(interestSql, period)).rows).toEqual(baseline.interest);
    expect(await interest()).toEqual(['partner:16', 'mec:3']);
    expect(await interest(null, null, false)).toEqual(['partner:16', 'mec:3']);
  });
  it('demographics: JSON byte-idêntico ao da função anterior', async () => {
    expect((await db.query<{ t: string }>(demographicsSql)).rows[0].t).toBe(baseline.demographics);
    expect((await db.query<{ t: string }>(
      'SELECT public.get_command_center_demographics(NULL::uuid, NULL::uuid, NULL::boolean)::text AS t')).rows[0].t).toBe(baseline.demographics);
  });
});

describe('opportunity interest por first-touch', () => {
  it('campanha, divulgador e combinação (AND no mesmo link); last-touch não conta', async () => {
    expect(await interest(A)).toEqual(['partner:8', 'mec:1']); // U1 3 + U2 4 + U7 1 (link arquivado)
    expect(await interest(B)).toEqual(['partner:2']); // só U3; U2 é last-touch B
    expect(await interest(null, X)).toEqual(['partner:6']); // U1 + U3 + U7
    expect(await interest(null, Y)).toEqual(['partner:4', 'mec:1']); // U2 (U4 sem cliques)
    expect(await interest(A, X)).toEqual(['partner:4']);
    expect(await interest(B, Y)).toEqual([]);
  });
  it('"sem atribuição" só conta cliques de logados sem first-touch; anônimos saem com filtro ativo', async () => {
    expect(await interest(null, null, true)).toEqual(['partner:1']); // U6; anon-1/anon-2 excluídos
  });
});

describe('demographics por first-touch', () => {
  it('recorta saúde do Match e as quatro dimensões, com somas = total', async () => {
    const a = await demographics(A);
    expect(a.match_health).toMatchObject({ total: 3, with_match: 1, without_match: 2 });
    expect(a.education).toEqual([
      { label: 'Ensino Médio Completo', value: 1 }, { label: 'Ensino Superior Completo', value: 1 }, { label: 'Não respondeu', value: 1 },
    ]);
    for (const [f, total] of [[await demographics(A), 3], [await demographics(null, X), 3], [await demographics(A, Y), 1],
      [await demographics(null, null, true), 2], [await demographics(B), 1]] as const) {
      expect(f.match_health.total).toBe(total);
      expect(f.match_health.with_match + f.match_health.without_match).toBe(total);
      for (const dim of ['education', 'income', 'race', 'school_type'] as const) {
        expect((f[dim] as { value: number }[]).reduce((s, x) => s + x.value, 0)).toBe(total);
      }
    }
    const b = await demographics(B);
    expect(b.match_health).toMatchObject({ total: 1, with_match: 0, attempted_no_result: 1 });
  });
  it('combinação sem link devolve zeros e listas vazias', async () => {
    const empty = await demographics(B, Y);
    expect(empty.match_health).toMatchObject({ total: 0, with_match: 0, without_match: 0 });
    expect(empty.education).toEqual([]);
  });
});

describe('contrato', () => {
  it('rejeita "sem atribuição" combinado com campanha/divulgador (22023)', async () => {
    await expect(interest(A, null, true)).rejects.toMatchObject({ code: '22023' });
    await expect(demographics(null, X, true)).rejects.toMatchObject({ code: '22023' });
  });
  it('nega não-admin (42501) mesmo com filtro', async () => {
    await db.exec("SET test.admin = 'false'; SET ROLE authenticated");
    await expect(interest(A)).rejects.toMatchObject({ code: '42501' });
    await expect(demographics(A)).rejects.toMatchObject({ code: '42501' });
    await db.exec("RESET ROLE; SET test.admin = 'true'");
  });
  it('uma assinatura por função, anon sem EXECUTE, authenticated com EXECUTE', async () => {
    const { rows } = await db.query<{ proname: string; args: string }>(`
      SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args FROM pg_proc p
      WHERE p.proname IN ('get_command_center_opportunity_interest', 'get_command_center_demographics') ORDER BY 1`);
    expect(rows).toEqual([
      { proname: 'get_command_center_demographics', args: 'p_filter_campaign_id uuid, p_filter_channel_id uuid, p_filter_unattributed boolean' },
      { proname: 'get_command_center_opportunity_interest',
        args: 'p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer, p_filter_campaign_id uuid, p_filter_channel_id uuid, p_filter_unattributed boolean' },
    ]);
    const sigI = 'public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer,uuid,uuid,boolean)';
    const sigD = 'public.get_command_center_demographics(uuid,uuid,boolean)';
    const acl = await db.query<Record<string, boolean>>(`SELECT
      has_function_privilege('anon', '${sigI}', 'EXECUTE') AS anon_i, has_function_privilege('anon', '${sigD}', 'EXECUTE') AS anon_d,
      has_function_privilege('authenticated', '${sigI}', 'EXECUTE') AS auth_i, has_function_privilege('authenticated', '${sigD}', 'EXECUTE') AS auth_d,
      (SELECT prosecdef FROM pg_proc WHERE oid = '${sigI}'::regprocedure) AS definer_i,
      (SELECT prosecdef FROM pg_proc WHERE oid = '${sigD}'::regprocedure) AS definer_d,
      (SELECT proconfig::text FROM pg_proc WHERE oid = '${sigI}'::regprocedure) = '{search_path=public}' AS path_i,
      (SELECT proconfig::text FROM pg_proc WHERE oid = '${sigD}'::regprocedure) = '{search_path=public}' AS path_d`);
    expect(acl.rows[0]).toEqual({ anon_i: false, anon_d: false, auth_i: true, auth_d: true,
      definer_i: true, definer_d: true, path_i: true, path_d: true });
  });
});
