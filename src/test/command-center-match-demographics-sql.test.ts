// @vitest-environment node
// Complemento TP-1 (card f245da71): executa a migration real num Postgres
// embutido. A bateria completa, contra o schema real do DEV e com rollback, está
// em supabase/tests/command-center-match-demographics/run_dev.sh.
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { CommandCenterDemographics } from '@/lib/analytics-queries';

let db: PGlite;
const migration = new URL('../../supabase/migrations/20261015204255_command_center_match_demographics_views.sql', import.meta.url);
const id = (n: number) => `7c1c0000-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;
const partnerA = '11111111-1111-4111-8111-111111111111';
const partnerB = '22222222-2222-4222-8222-222222222222';

beforeAll(async () => {
  db = new PGlite();
  await db.exec(`
    CREATE ROLE authenticated; CREATE ROLE anon; CREATE ROLE service_role; CREATE ROLE partner IN ROLE authenticated;
    CREATE FUNCTION public.is_backoffice_admin() RETURNS boolean LANGUAGE sql AS
      $$ SELECT coalesce(current_setting('test.admin', true), '') = 'true' $$;
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

    INSERT INTO partner_forms VALUES
      ('${id(1001)}', '${partnerA}', 'edu',    'Escolaridade', 'user_profiles.education'),
      ('${id(1002)}', '${partnerA}', 'escola', 'Você estuda/estudou em que tipo de escola?', NULL),
      ('${id(1003)}', '${partnerA}', 'renda',  'Renda per capita', 'user_income.per_capita_income'),
      ('${id(1004)}', '${partnerB}', 'edu_b',  'Escolaridade', 'user_profiles.education');

    INSERT INTO user_profiles (id) SELECT ('7c1c0000-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid FROM generate_series(1, 9) n;
    UPDATE user_profiles SET education = 'Pós-Gradução' WHERE id = '${id(6)}';
    UPDATE user_profiles SET education = 'Ensino Médio Completo' WHERE id = '${id(7)}';

    -- 1: só v0 resultado · 2: só conversa v0 · 3: só parceiro, sem preferências
    -- 4: erro v1 sem resultado · 5: nunca
    INSERT INTO user_preferences (user_id, workflow_data, match_status, last_match_at, family_income_per_capita) VALUES
      ('${id(1)}', '{"last_course_ids":["x"]}', 'reviewing', NULL, NULL),
      ('${id(4)}', NULL, 'error', '2026-08-01', NULL),
      ('${id(5)}', NULL, 'idle', NULL, NULL),
      ('${id(99)}', '{"last_course_ids":["orfao"]}', 'reviewing', NULL, NULL);
    INSERT INTO chat_messages (user_id, workflow, created_at) VALUES ('${id(2)}', 'match_workflow', '2026-01-20');
    INSERT INTO user_opportunity_matches (profile_id, unified_opportunity_id, generated_at) VALUES ('${id(3)}', 'partner_x', '2026-08-01');
    INSERT INTO user_income (user_id, per_capita_income) VALUES ('${id(9)}', 2000);

    -- 6: rótulo com erro no perfil · 7: perfil vence form · 8: dois forms, o mais
    -- recente vence (e não o MAX lexical) · 9: renda exata vence faixa SM
    INSERT INTO student_applications VALUES
      ('${id(2001)}', '${id(7)}', '${partnerA}', 'SUBMITTED', '{"edu":"Ensino Superior Completo"}', '2026-09-01', '2026-09-01'),
      ('${id(2002)}', '${id(8)}', '${partnerA}', 'SUBMITTED', '{"edu":"Ensino Superior Completo","renda":"Até 1 salário mínimo"}', '2026-09-01', '2026-09-01'),
      ('${id(2003)}', '${id(8)}', '${partnerB}', 'DRAFT', '{"edu_b":"Ensino Fundamental"}', '2026-10-01', '2026-10-01'),
      ('${id(2004)}', '${id(5)}', '${partnerA}', 'redirected', '{"${id(1002)}":"Escola pública","edu_b":"Ensino Superior Completo"}', '2026-09-02', '2026-09-02'),
      ('${id(2005)}', '${id(9)}', '${partnerA}', 'redirected', '{"renda":"De 1 a 2 salários mínimos"}', '2026-09-02', '2026-09-02');
  `);
  await db.exec(readFileSync(migration, 'utf8'));
  await db.exec("SET test.admin = 'true'");
}, 30000);
afterAll(async () => db?.close());

const rpc = async () =>
  (await db.query<{ j: CommandCenterDemographics }>('SELECT public.get_command_center_demographics()::jsonb AS j')).rows[0].j;
const slice = (j: CommandCenterDemographics, dim: 'education' | 'income' | 'race' | 'school_type', label: string) =>
  j[dim].find((s) => s.label === label)?.value ?? 0;

describe('vw_user_match_evidence', () => {
  it('classifica cada perfil uma vez, sem órfãos', async () => {
    const { rows } = await db.query<{ profile_id: string; bucket: string }>(
      'SELECT profile_id, bucket FROM public.vw_user_match_evidence ORDER BY profile_id');
    expect(rows.map((r) => r.bucket)).toEqual([
      'concluded', 'attempted_no_result', 'concluded', 'attempted_no_result', 'never', 'never', 'never', 'never', 'never',
    ]);
  });
});

describe('vw_user_demographics_resolved', () => {
  it('aplica precedência, proveniência e normalização só na view', async () => {
    const { rows } = await db.query<Record<string, unknown>>(
      'SELECT profile_id, education, education_source, education_source_status, education_conflict, school_type, income_brl, income_band_sm, income_source FROM public.vw_user_demographics_resolved ORDER BY profile_id');
    const byId = Object.fromEntries(rows.map((r) => [r.profile_id, r]));
    expect(byId[id(6)].education).toBe('Pós-Graduação');
    expect(byId[id(7)]).toMatchObject({ education: 'Ensino Médio Completo', education_source: 'profile', education_conflict: true });
    expect(byId[id(8)]).toMatchObject({ education: 'Ensino Fundamental', education_source_status: 'DRAFT', education_conflict: true,
      income_brl: null, income_band_sm: 'Até 1 salário mínimo' });
    // edu_b pertence ao parceiro B; a candidatura é do parceiro A.
    expect(byId[id(5)]).toMatchObject({ education: null, school_type: 'Escola pública' });
    expect(byId[id(9)]).toMatchObject({ income_band_sm: null, income_source: 'profile' });
    expect(Number(byId[id(9)].income_brl)).toBe(2000);
    const { rows: stored } = await db.query<{ education: string }>(`SELECT education FROM user_profiles WHERE id = '${id(6)}'`);
    expect(stored[0].education).toBe('Pós-Gradução');
  });
});

describe('get_command_center_demographics', () => {
  it('preserva as chaves atuais e acrescenta as novas, com somas coerentes', async () => {
    const j = await rpc();
    expect(j.match_health).toEqual({
      with_match: 2, without_match: 7, total: 9,
      attempted_no_result: 2, never: 5, with_current_result: 1, with_current_mec_result: 0,
    });
    for (const dim of ['education', 'income', 'race', 'school_type'] as const) {
      expect(j[dim].reduce((a, s) => a + s.value, 0)).toBe(9);
    }
    expect(slice(j, 'income', 'Faixa declarada em salários mínimos')).toBe(1);
    expect(j.income.at(-1)?.label).toBe('Não respondeu');
    expect(j.provenance?.education).toMatchObject({ profile: 2, partner_form: 1, conflicts: 2 });
    expect(await rpc()).toEqual(j);
  });

  it('nega não-admin e mantém as views fora do alcance dos papéis de API', async () => {
    await db.exec("SET test.admin = 'false'; SET ROLE authenticated");
    await expect(rpc()).rejects.toMatchObject({ code: '42501' });
    await db.exec("RESET ROLE; SET test.admin = 'true'; SET ROLE authenticated");
    expect((await rpc()).match_health.total).toBe(9);
    await expect(db.query('SELECT 1 FROM public.vw_user_match_evidence')).rejects.toMatchObject({ code: '42501' });
    await db.exec('RESET ROLE');
    const { rows } = await db.query<Record<string, boolean>>(`SELECT
      has_function_privilege('anon', 'public.get_command_center_demographics()', 'EXECUTE') AS anon_rpc,
      has_table_privilege('anon', 'public.vw_user_demographics_resolved', 'SELECT') AS anon_view,
      has_table_privilege('authenticated', 'public.vw_user_demographics_resolved', 'SELECT') AS auth_view`);
    expect(rows[0]).toEqual({ anon_rpc: false, anon_view: false, auth_view: false });
  });
});
