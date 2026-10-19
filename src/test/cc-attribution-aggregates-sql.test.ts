// @vitest-environment node
// NUB-RD-93 — contrato das RPCs cc_stats_aggregate, cc_activity_aggregate e
// cc_rankings_aggregate executado num Postgres embutido com a migration real.
// A bateria contra o schema real do DEV, com rollback, está em
// supabase/tests/command_center_attribution_filters/ (assert_aggregates.sql).
import type { PGlite } from '@electric-sql/pglite';
import { aggregatesDb, type Tables } from './ccAggregatesDb';

const FUNCTIONS = {
  cc_stats_aggregate: 'timestamptz,timestamptz,timestamptz,boolean,uuid,uuid,boolean',
  cc_activity_aggregate: 'text,timestamptz,timestamptz,text,integer,uuid,uuid,boolean',
  cc_rankings_aggregate: 'text,timestamptz,timestamptz,uuid,uuid,boolean',
};
const A = 'aaaaaaaa-0000-4000-8000-00000000000a', X = 'bbbbbbbb-0000-4000-8000-00000000000e';
const L1 = 'dddddddd-0000-4000-8000-000000000001', L2 = 'dddddddd-0000-4000-8000-000000000002';
const u = (n: number) => `cccccccc-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;
const from = '2026-06-15T03:00:00Z', to = '2026-06-16T03:00:00Z', prev = '2026-06-14T03:00:00Z';

// 1 first L1 (A,X) · 2 first L2 (sem campanha, X) · 3 linha sem first-touch · 4 sem linha
// 5 dependente (perfil sem auth próprio) sem atribuição · 6 sem perfil, first L1 · 7 sem perfil e sem linha
const tables: Tables = {
  channel_links: [{ id: L1, campaign_id: A, channel_id: X }, { id: L2, campaign_id: null, channel_id: X }],
  user_attribution: [
    { user_id: u(1), first_touch_link_id: L1 }, { user_id: u(2), first_touch_link_id: L2 },
    { user_id: u(3), first_touch_link_id: null, last_touch_link_id: L1 }, { user_id: u(6), first_touch_link_id: L1 },
  ],
  user_profiles: [1, 2, 3, 4, 5].map(n => ({ id: u(n), full_name: 'P' + n, city: 'Natal' })),
  chat_messages: [1, 2, 3, 4, 5, 6, 7].map(n => ({ user_id: u(n), sender: 'user', created_at: '2026-06-15T12:00:00Z' })),
};

let db: PGlite;
beforeAll(async () => { db = await aggregatesDb(tables); });
afterAll(async () => { await db?.close(); });

const one = async <T = any>(sql: string, params: unknown[] = []) => (await db.query<{ r: T }>(sql, params)).rows[0].r;
const stats = (filter = 'NULL, NULL, NULL') =>
  one(`SELECT public.cc_stats_aggregate('${from}', '${to}', '${prev}', false, ${filter}) AS r`);
const sqlState = async (sql: string) => {
  try { await db.query(sql); return 'sem erro'; } catch (error: any) { return error.code; }
};

describe('ACL e atributos', () => {
  it.each(Object.entries(FUNCTIONS))('%s: uma assinatura, SECURITY DEFINER, search_path fixo', async (name, args) => {
    expect(await one(`SELECT count(*)::int AS r FROM pg_proc WHERE proname = $1`, [name])).toBe(1);
    expect(await one(`SELECT to_regprocedure($1) IS NOT NULL AS r`, [`public.${name}(${args})`])).toBe(true);
    expect(await one(`SELECT prosecdef::text || ' ' || proconfig::text AS r FROM pg_proc WHERE proname = $1`, [name]))
      .toBe('true {"search_path=public, pg_temp"}');
  });
  it.each(Object.entries(FUNCTIONS))('%s: anon e PUBLIC sem EXECUTE; authenticated e service_role com', async (name, args) => {
    const fn = `public.${name}(${args})`;
    const can = (role: string) => one(`SELECT has_function_privilege('${role}', '${fn}', 'EXECUTE') AS r`);
    expect([await can('anon'), await can('authenticated'), await can('service_role')]).toEqual([false, true, true]);
    expect(await one(`SELECT coalesce(bool_or(a.grantee = 0), false) AS r FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = '${fn}'::regprocedure`)).toBe(false);
  });
  it.each([
    `SELECT public.cc_stats_aggregate('${from}', '${to}', '${prev}', false)`,
    `SELECT public.cc_activity_aggregate('week', '${from}', '${to}')`,
    `SELECT public.cc_rankings_aggregate('users', '${from}', '${to}')`,
  ])('authenticated não-backoffice → 42501: %s', async sql => {
    await db.exec("SET test.role = 'authenticated'; SET test.admin = 'false'");
    try {
      expect(await sqlState(sql)).toBe('42501');
      await db.exec("SET test.admin = 'true'");
      expect(await sqlState(sql)).toBe('sem erro');
    } finally {
      await db.exec("SET test.role = 'service_role'; SET test.admin = 'false'");
    }
  });
  it.each([
    [`SELECT public.cc_stats_aggregate('${from}', '${to}', '${prev}', false, '${A}', NULL, true)`, '22023'],
    [`SELECT public.cc_stats_aggregate('${to}', '${from}', '${prev}', false)`, '22023'],
    [`SELECT public.cc_activity_aggregate('week', '${from}', NULL)`, '22023'],
    [`SELECT public.cc_activity_aggregate('month', NULL, NULL)`, '22023'],
    [`SELECT public.cc_activity_aggregate('day', NULL, NULL, 'America/Sao_Paulo', 24)`, '22023'],
    [`SELECT public.cc_activity_aggregate('week', NULL, NULL, 'Mars/Olympus')`, '22023'],
    [`SELECT public.cc_rankings_aggregate('nope')`, '22023'],
    [`SELECT public.cc_rankings_aggregate('users')`, '22023'],
    [`SELECT public.cc_rankings_aggregate('courses', NULL, NULL, NULL, '${X}', true)`, '22023'],
  ])('entrada inválida → %s', async (sql, state) => {
    expect(await sqlState(sql)).toBe(state);
  });
});

describe('recorte first-touch', () => {
  it('"sem atribuição" usa o universo de user_profiles (inclui dependente, exclui quem não tem perfil)', async () => {
    const s = await stats('NULL, NULL, true');
    expect(s.total_registered).toBe(3); // 3, 4, 5
    expect(s.current_messages).toBe(3); // 7 não tem perfil: fica fora, como antes
    expect(await one(`SELECT count(*)::int AS r FROM user_profiles p
      WHERE public.matches_first_touch_attribution(p.id, NULL, NULL, true)`)).toBe(3);
  });
  it('campanha/divulgador: mesmo conjunto de matches_first_touch_attribution, com ou sem perfil', async () => {
    for (const [filter, campaign, channel] of [[`'${A}', NULL, NULL`, A, null], [`NULL, '${X}', NULL`, null, X], [`'${A}', '${X}', NULL`, A, X]]) {
      const s = await stats(filter as string);
      const expected = await one(`SELECT count(DISTINCT m.id)::int AS r FROM chat_messages m
        WHERE m.user_id IS NOT NULL AND public.matches_first_touch_attribution(m.user_id, $1, $2, NULL)`, [campaign, channel]);
      expect(s.current_messages).toBe(expected);
      expect(s.total_registered).toBe(await one(`SELECT count(*)::int AS r FROM user_profiles p
        WHERE public.matches_first_touch_attribution(p.id, $1, $2, NULL)`, [campaign, channel]));
    }
  });
  it('sem filtro e unattributed=false são o mesmo resultado', async () => {
    expect(await stats('NULL, NULL, false')).toEqual(await stats());
    expect((await stats()).total_registered).toBeNull();
  });
});
