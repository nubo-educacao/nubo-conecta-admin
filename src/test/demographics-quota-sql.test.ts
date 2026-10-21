// @vitest-environment node
// NUB-RD-92 (TP-B 88f53add rev. 2): demografia inferida por cota. Executa as
// migrations reais num Postgres embutido — views de 20261015204255, helpers do
// TP-7, RPC de 20261016140000 e a migration nova por cima. A bateria contra o
// schema real do DEV, com rollback, está em supabase/tests/demographics_quota/.
import { PGlite } from '@electric-sql/pglite';
import { unaccent } from '@electric-sql/pglite/contrib/unaccent';
import { readFileSync } from 'node:fs';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { CommandCenterDemographics } from '@/lib/analytics-queries';

const file = (name: string) => readFileSync(new URL(`../../supabase/migrations/${name}`, import.meta.url), 'utf8');
const NEW_MIGRATION = '20261019170042_demographics_quota_inferred.sql';

const tp7 = file('20261015202330_tp7_first_touch_attribution_filters.sql');
const tp7Helpers = tp7.slice(0, tp7.indexOf('-- ─── get_students_paginated'));
const ccaf = file('20261016140000_command_center_attribution_filters.sql');
const ccafDemographics = ccaf.slice(ccaf.indexOf('-- ─── get_command_center_demographics'));

const id = (n: number) => `9b920000-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;
const A = '9b920000-0000-4000-a000-00000000000a';
const B = '9b920000-0000-4000-a000-00000000000b';
const X = '9b920000-0000-4000-b000-00000000000e';
const L1 = '9b920000-0000-4000-c000-000000000001';
const L3 = '9b920000-0000-4000-c000-000000000003';

let db: PGlite;

const rpc = async (args = '') =>
  (await db.query<{ j: CommandCenterDemographics }>(`SELECT public.get_command_center_demographics(${args})::jsonb AS j`)).rows[0].j;
const slices = (j: CommandCenterDemographics, dim: 'race' | 'school_type') =>
  j[dim].map((s) => `${s.label}=${s.value}`).join(',');
const fingerprint = async () =>
  (await db.query<{ f: string }>(`SELECT md5(
     (SELECT coalesce(string_agg(t::text, ',' ORDER BY t.id), '') FROM user_profiles t) ||
     (SELECT coalesce(string_agg(t::text, ',' ORDER BY t.id), '') FROM user_preferences t)) AS f`)).rows[0].f;

beforeAll(async () => {
  db = new PGlite({ extensions: { unaccent } });
  await db.exec(`
    CREATE EXTENSION unaccent SCHEMA public;
    CREATE ROLE authenticated; CREATE ROLE anon; CREATE ROLE service_role; CREATE ROLE partner IN ROLE authenticated;
    CREATE FUNCTION public.is_backoffice_admin() RETURNS boolean LANGUAGE sql AS
      $$ SELECT coalesce(current_setting('test.admin', true), '') = 'true' $$;

    CREATE TABLE channel_links (id uuid PRIMARY KEY, campaign_id uuid, channel_id uuid NOT NULL, archived_at timestamptz);
    CREATE TABLE user_attribution (user_id uuid PRIMARY KEY, first_touch_link_id uuid, last_touch_link_id uuid);
    CREATE TABLE user_profiles (id uuid PRIMARY KEY, parent_user_id uuid, education text, race text, school_type text);
    CREATE TABLE user_preferences (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid UNIQUE NOT NULL, workflow_data jsonb,
      match_status text, last_match_at timestamptz, family_income_per_capita numeric, quota_types text[],
      updated_at timestamptz NOT NULL DEFAULT '2026-10-01T12:00:00Z');
    CREATE TABLE user_income (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid UNIQUE NOT NULL, per_capita_income numeric);
    CREATE TABLE user_opportunity_matches (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), profile_id uuid NOT NULL,
      unified_opportunity_id text NOT NULL, generated_at timestamptz);
    CREATE TABLE chat_messages (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid, workflow text, created_at timestamptz);
    CREATE TABLE partner_forms (id uuid PRIMARY KEY, partner_id uuid NOT NULL, field_name text NOT NULL,
      question_text text NOT NULL, mapping_source text);
    CREATE TABLE student_applications (id uuid PRIMARY KEY, user_id uuid NOT NULL, partner_id uuid NOT NULL, status text NOT NULL,
      answers jsonb NOT NULL, created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL);
  `);
  await db.exec(file('20261015204255_command_center_match_demographics_views.sql'));
  await db.exec(tp7Helpers);
  await db.exec(ccafDemographics);

  await db.exec(`
    INSERT INTO user_profiles (id) SELECT ('9b920000-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid
      FROM generate_series(1, 18) n WHERE n <> 16;
    UPDATE user_profiles SET race = 'Preta'                WHERE id = '${id(2)}';
    UPDATE user_profiles SET race = 'Prefiro não informar' WHERE id = '${id(3)}';
    UPDATE user_profiles SET school_type = 'Escola particular sem bolsa' WHERE id = '${id(12)}';
    UPDATE user_profiles SET race = 'Parda'                WHERE id = '${id(13)}';

    INSERT INTO user_preferences (user_id, quota_types, updated_at) VALUES
      ('${id(1)}',  ARRAY['PPI'], '2026-10-02T10:00:00Z'),
      ('${id(2)}',  ARRAY['PPI'], DEFAULT),
      ('${id(3)}',  ARRAY['PPI'], DEFAULT),
      ('${id(4)}',  ARRAY['PPI','PRETOS E PARDOS','INDIGENAS'], DEFAULT),
      ('${id(5)}',  ARRAY['ppi','PRETOS E PARDOS'], DEFAULT),
      ('${id(6)}',  ARRAY['ESCOLA_PUBLICA'], DEFAULT),
      ('${id(7)}',  ARRAY['escola pública'], DEFAULT),
      ('${id(8)}',  ARRAY['ESCOLA_PRIVADA_BOLSA_INTEGRAL'], DEFAULT),
      ('${id(9)}',  ARRAY['bolsa integral'], DEFAULT),
      ('${id(10)}', ARRAY['ESCOLA_PUBLICA','ESCOLA_PRIVADA_BOLSA_INTEGRAL'], DEFAULT),
      ('${id(11)}', ARRAY['QUILOMBOLAS','QUILOMBOLA','ppiq','BAIXA_RENDA','AMPLA_CONCORRENCIA','PCD','PDC','100%'], DEFAULT),
      ('${id(12)}', ARRAY['ESCOLA_PUBLICA'], DEFAULT),
      ('${id(14)}', ARRAY['Indígena'], DEFAULT),
      ('${id(17)}', ARRAY[]::text[], DEFAULT),
      ('${id(18)}', ARRAY['  Pretos-e-Pardos ', NULL, ''], DEFAULT);

    -- Só o L1 (campanha A, divulgador X) tem gente; a campanha B fica vazia.
    INSERT INTO channel_links VALUES ('${L1}', '${A}', '${X}', NULL), ('${L3}', '${B}', '${X}', NULL);
    INSERT INTO user_attribution VALUES ('${id(1)}', '${L1}', '${L1}'), ('${id(6)}', '${L1}', '${L1}');
  `);
}, 30000);
afterAll(async () => db?.close());

describe('migration aplicada sobre a definição vigente', () => {
  it('aplica a migration nova sem alterar perfis nem preferências', async () => {
    const before = await fingerprint();
    await db.exec(file(NEW_MIGRATION));
    await db.exec("SET test.admin = 'true'");
    await rpc();
    await db.query('SELECT count(*) FROM public.vw_user_demographics_resolved');
    expect(await fingerprint()).toBe(before);
  });
});

describe('normalize_quota_token', () => {
  it('normaliza caixa, acento, espaço e hífen; vazio vira NULL', async () => {
    const { rows } = await db.query<Record<string, string | null>>(`SELECT
      public.normalize_quota_token('  Escola Pública ') AS a,
      public.normalize_quota_token('PRETOS E PARDOS') AS b,
      public.normalize_quota_token('Pretos-e-Pardos') AS c,
      public.normalize_quota_token('INDÍGENAS') AS d,
      public.normalize_quota_token('100%') AS e,
      public.normalize_quota_token('   ') AS f,
      public.normalize_quota_token(NULL) AS g`);
    expect(rows[0]).toEqual({ a: 'escola_publica', b: 'pretos_e_pardos', c: 'pretos_e_pardos', d: 'indigenas', e: '100%', f: null, g: null });
    const { rows: meta } = await db.query<{ v: string }>(
      "SELECT provolatile AS v FROM pg_proc WHERE proname = 'normalize_quota_token'");
    expect(meta).toEqual([{ v: 'i' }]);
  });
});

describe('vw_user_demographics_resolved', () => {
  it('só acrescenta colunas ao final e troca rule_version', async () => {
    const { rows } = await db.query<{ column_name: string }>(`SELECT column_name FROM information_schema.columns
      WHERE table_name = 'vw_user_demographics_resolved' ORDER BY ordinal_position`);
    const cols = rows.map((r) => r.column_name);
    expect(cols.slice(0, 2)).toEqual(['profile_id', 'rule_version']);
    expect(cols.at(-6)).toBe('income_conflict');
    expect(cols.slice(-5)).toEqual([
      'race_quota_label', 'school_type_quota_label', 'quota_source_date', 'school_type_quota_conflict', 'quota_has_unmapped',
    ]);
    const { rows: rv } = await db.query<{ v: string }>('SELECT DISTINCT rule_version AS v FROM public.vw_user_demographics_resolved');
    expect(rv).toEqual([{ v: 'tp1c-2026-10-15.v1+nub-rd-92' }]);
  });

  it('infere por cota só sem autodeclaração, com precedência N3 e sem tocar race/school_type', async () => {
    const { rows } = await db.query<Record<string, unknown>>(`SELECT profile_id, race, race_quota_label, school_type,
      school_type_quota_label, school_type_quota_conflict, quota_source_date, quota_has_unmapped
      FROM public.vw_user_demographics_resolved`);
    const by = Object.fromEntries(rows.map((r) => [r.profile_id, r]));
    expect(by[id(1)]).toMatchObject({ race: null, race_quota_label: 'PPI (por cota)' });
    expect(new Date(by[id(1)].quota_source_date as string).toISOString()).toBe('2026-10-02T10:00:00.000Z');
    expect(by[id(2)]).toMatchObject({ race: 'Preta', race_quota_label: null });
    expect(by[id(3)]).toMatchObject({ race: 'Prefiro não informar', race_quota_label: null });
    expect(by[id(4)]).toMatchObject({ race_quota_label: 'Indígena (por cota)' });
    expect(by[id(5)]).toMatchObject({ race_quota_label: 'Pretos e pardos (por cota)' });
    expect(by[id(14)]).toMatchObject({ race_quota_label: 'Indígena (por cota)' });
    expect(by[id(18)]).toMatchObject({ race_quota_label: 'Pretos e pardos (por cota)', quota_has_unmapped: false });
    expect(by[id(6)]).toMatchObject({ school_type: null, school_type_quota_label: 'Escola pública (por cota)', race_quota_label: null });
    expect(by[id(7)]).toMatchObject({ school_type_quota_label: 'Escola pública (por cota)' });
    expect(by[id(8)]).toMatchObject({ school_type_quota_label: 'Privada com bolsa integral (por cota)' });
    expect(by[id(9)]).toMatchObject({ school_type_quota_label: 'Privada com bolsa integral (por cota)' });
    expect(by[id(10)]).toMatchObject({ school_type_quota_label: null, school_type_quota_conflict: true });
    expect(by[id(11)]).toMatchObject({ race_quota_label: null, school_type_quota_label: null, quota_has_unmapped: true });
    expect(by[id(12)]).toMatchObject({ school_type: 'Escola particular sem bolsa', school_type_quota_label: null, school_type_quota_conflict: false });
    for (const n of [13, 15, 17]) {
      expect(by[id(n)]).toMatchObject({ race_quota_label: null, school_type_quota_label: null, quota_source_date: null,
        school_type_quota_conflict: false, quota_has_unmapped: false });
    }
  });
});

describe('get_command_center_demographics', () => {
  it('rótulos "(por cota)" separados dos autodeclarados, sem somar com eles', async () => {
    const j = await rpc();
    expect(j.match_health.total).toBe(17);
    expect(slices(j, 'race')).toBe(
      'Parda=1,Prefiro não informar=1,Preta=1,Indígena (por cota)=2,Pretos e pardos (por cota)=2,PPI (por cota)=1,Não respondeu=9');
    expect(slices(j, 'school_type')).toBe(
      'Escola particular sem bolsa=1,Escola pública (por cota)=2,Privada com bolsa integral (por cota)=2,Não respondeu=12');
    expect(j.race.map((s) => s.source)).toEqual([
      'self_declared', 'self_declared', 'self_declared', 'quota_inferred', 'quota_inferred', 'quota_inferred', 'unanswered']);
    for (const dim of ['education', 'income', 'race', 'school_type'] as const) {
      expect(j[dim].reduce((a, s) => a + s.value, 0)).toBe(17);
    }
  });

  it('provenance ganha quota_inferred/quota_unmapped/quota_conflict sem perder as chaves antigas', async () => {
    const j = await rpc();
    expect(j.provenance?.rule_version).toBe('tp1c-2026-10-15.v1+nub-rd-92');
    expect(j.provenance?.race).toEqual({
      profile: 3, partner_form: 0, unanswered: 14, conflicts: 0, declined: 1, quota_inferred: 5, quota_unmapped: 1,
    });
    expect(j.provenance?.school_type).toEqual({
      profile: 1, partner_form: 0, unanswered: 16, conflicts: 0, quota_inferred: 4, quota_unmapped: 1, quota_conflict: 1,
    });
  });

  it('coverage por perfil único: autodeclarado + por cota + sem cobertura = total; recusa fica em uncovered', async () => {
    const j = await rpc();
    expect(j.coverage?.race).toEqual({
      total_users: 17, self_declared: 2, quota_inferred: 5, uncovered: 10, declined: 1,
      self_declared_pct: 11.8, quota_inferred_pct: 29.4, uncovered_pct: 58.8, covered_pct: 41.2,
    });
    expect(j.coverage?.school_type).toEqual({
      total_users: 17, self_declared: 1, quota_inferred: 4, uncovered: 12,
      self_declared_pct: 5.9, quota_inferred_pct: 23.5, uncovered_pct: 70.6, covered_pct: 29.4,
    });
  });

  it('recorte first-touch vale também para as linhas inferidas por cota', async () => {
    const j = await rpc(`p_filter_campaign_id => '${A}'`);
    expect(j.match_health.total).toBe(2);
    expect(slices(j, 'race')).toBe('PPI (por cota)=1,Não respondeu=1');
    expect(slices(j, 'school_type')).toBe('Escola pública (por cota)=1,Não respondeu=1');
    expect(j.coverage?.race).toMatchObject({ total_users: 2, quota_inferred: 1, uncovered: 1, covered_pct: 50 });
  });

  it('total_users = 0 devolve percentuais NULL, sem divisão por zero', async () => {
    const j = await rpc(`p_filter_campaign_id => '${B}'`);
    expect(j.match_health.total).toBe(0);
    expect(j.coverage?.race).toEqual({
      total_users: 0, self_declared: 0, quota_inferred: 0, uncovered: 0, declined: 0,
      self_declared_pct: null, quota_inferred_pct: null, uncovered_pct: null, covered_pct: null,
    });
    expect(j.coverage?.school_type.covered_pct).toBeNull();
  });

  it('mantém assinatura única, guarda de admin e ACL fechada', async () => {
    const { rows } = await db.query<{ n: number; args: string; res: string }>(`SELECT count(*)::int AS n,
      min(pg_get_function_identity_arguments(oid)) AS args, min(pg_get_function_result(oid)) AS res
      FROM pg_proc WHERE proname = 'get_command_center_demographics'`);
    expect(rows[0]).toEqual({ n: 1, args: 'p_filter_campaign_id uuid, p_filter_channel_id uuid, p_filter_unattributed boolean', res: 'json' });

    await db.exec("SET test.admin = 'false'; SET ROLE authenticated");
    await expect(rpc()).rejects.toMatchObject({ code: '42501' });
    await expect(db.query('SELECT 1 FROM public.vw_user_demographics_resolved')).rejects.toMatchObject({ code: '42501' });
    await expect(db.query("SELECT public.normalize_quota_token('ppi')")).rejects.toMatchObject({ code: '42501' });
    await db.exec("RESET ROLE; SET test.admin = 'true'");

    const { rows: acl } = await db.query<Record<string, boolean>>(`SELECT
      has_function_privilege('anon', 'public.get_command_center_demographics(uuid,uuid,boolean)', 'EXECUTE') AS anon_rpc,
      has_function_privilege('authenticated', 'public.get_command_center_demographics(uuid,uuid,boolean)', 'EXECUTE') AS auth_rpc,
      has_function_privilege('anon', 'public.normalize_quota_token(text)', 'EXECUTE') AS anon_norm,
      has_function_privilege('authenticated', 'public.normalize_quota_token(text)', 'EXECUTE') AS auth_norm,
      has_table_privilege('authenticated', 'public.vw_user_demographics_resolved', 'SELECT') AS auth_view,
      has_table_privilege('service_role', 'public.vw_user_demographics_resolved', 'SELECT') AS svc_view`);
    expect(acl[0]).toEqual({ anon_rpc: false, auth_rpc: true, anon_norm: false, auth_norm: false, auth_view: false, svc_view: false });
  });
});
