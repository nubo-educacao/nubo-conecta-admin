// NUB-RD-93 — oráculo diferencial das Edges analytics-stats/activity/rankings.
//
// Roda a versão ANTERIOR de cada Edge (lida do Git em BASE, recorte em memória
// sobre um PostgREST simulado) e a versão ATUAL (uma RPC cc_*_aggregate,
// executada num Postgres embutido com a migration real) sobre os MESMOS dados,
// e compara status + corpo da resposta byte a byte, célula por célula.
//
//   node supabase/tests/cc_perf/differential.mjs                    # dados sintéticos (semente fixa)
//   node supabase/tests/cc_perf/differential.mjs --seed 7 --users 400
//   node supabase/tests/cc_perf/differential.mjs --data dump.json  # dump real (dump_dev.sh)
//
// BASE padrão: 4cb20f1b (main antes do NUB-RD-93). Precisa do histórico Git.
// Saída: DIFF_ALL_PASS <n> células, ou a primeira divergência de cada célula.
import { PGlite } from '@electric-sql/pglite';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, posix, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, value, i, all) =>
  value.startsWith('--') ? [...acc, [value.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : 'true']] : acc, []));
const BASE = args.base ?? '4cb20f1b12fee41546225f6d0cb1e012349003b2';
const ENTRIES = ['analytics-stats', 'analytics-activity', 'analytics-rankings'];

// ─── carregamento das Edges (mesma técnica do src/test/edgeHarness.ts) ──────

function loadEdge(entry, readSource, client) {
  let handler;
  const cache = new Map();
  const load = path => {
    if (cache.has(path)) return cache.get(path);
    const exports = {};
    cache.set(path, exports);
    const compiled = ts.transpileModule(readSource(path), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    const require = name => name.startsWith('https://') ? { createClient: () => client } : load(posix.join(posix.dirname(path), name));
    new Function('exports', 'require', 'Deno', 'console', compiled)(exports, require,
      { serve: fn => { handler = fn; }, env: { get: () => 'differential' } }, { log() {}, error() {} });
    return exports;
  };
  load(`supabase/functions/${entry}/index.ts`);
  return handler;
}
const gitSource = path => execFileSync('git', ['show', `${BASE}:${path}`], { cwd: root, encoding: 'utf8', maxBuffer: 1 << 26 });
const workSource = path => readFileSync(resolve(root, path), 'utf8');

// ─── dados ───────────────────────────────────────────────────────────────────

function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (s + 0x6d2b79f5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
const uuid = (r) => {
  const h = Array.from({ length: 32 }, () => Math.floor(r() * 16).toString(16)).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
// Formato do PostgREST para timestamptz, com microssegundos (testa o truncamento do Date.parse).
const pgTime = (ms, micro = 0) => new Date(ms).toISOString().replace('Z', '').padEnd(23, '0') + String(micro).padStart(3, '0') + '+00:00';

function synthetic(seed, users, now) {
  const r = rng(seed);
  const pick = list => list[Math.floor(r() * list.length)];
  const campaigns = [uuid(r), uuid(r), uuid(r)], channels = [uuid(r), uuid(r), uuid(r), uuid(r)];
  const links = Array.from({ length: 12 }, () => ({ id: uuid(r), campaign_id: r() < 0.15 ? null : pick(campaigns), channel_id: pick(channels),
    archived_at: r() < 0.2 ? pgTime(now - 86400000) : null }));
  const people = Array.from({ length: users }, () => uuid(r));
  const cities = ['São Paulo', 'são paulo - sp', 'SÃO PAULO', 'Recife - PE', 'recife', 'Rio  de Janeiro', 'Natal', 'natal - rn', ' - RJ', '', 'Évora', 'belo horizonte', 'Belo Horizonte - MG', 'ÁGUAS LINDAS'];
  const courses = ['Medicina', 'medicina', 'DIREITO', 'Direito', '  ', 'engenharia civil', 'Engenharia  Civil', 'Psicologia', 'ciência da computação'];
  const programs = ['sisu', 'prouni', 'fies', '', 'Sisu'];
  const profiles = people.filter(() => r() < 0.85).map(id => ({ id, full_name: r() < 0.1 ? (r() < 0.5 ? '' : null) : 'Pessoa ' + id.slice(0, 4), city: r() < 0.2 ? null : pick(cities) }));
  const user_attribution = people.filter(() => r() < 0.6).map(user_id => ({ user_id, first_touch_link_id: r() < 0.2 ? null : pick(links).id, last_touch_link_id: pick(links).id }));
  const span = 40 * 86400000;
  const chat_messages = [];
  for (const id of people) {
    let t = now - Math.floor(r() * span);
    const n = Math.floor(r() * r() * 30);
    for (let i = 0; i < n; i++) {
      t += Math.floor(r() < 0.5 ? r() * 20 * 60000 : r() * 3 * 86400000);
      if (t >= now - 5000) break;
      chat_messages.push({ id: uuid(r), user_id: id, sender: pick(['user', 'user', 'user', 'cloudinha', 'system', null]), created_at: pgTime(t, Math.floor(r() * 1000)) });
    }
  }
  for (let i = 0; i < users / 4; i++) chat_messages.push({ id: uuid(r), user_id: null, sender: 'user', created_at: pgTime(now - Math.floor(r() * span)) });
  // Fronteiras de 30 min exatas, sessão por milissegundo.
  const edge = people[0], base = now - 3 * 86400000;
  chat_messages.push({ id: uuid(r), user_id: edge, sender: 'user', created_at: pgTime(base) },
    { id: uuid(r), user_id: edge, sender: 'user', created_at: pgTime(base + 1800000, 999) },
    { id: uuid(r), user_id: edge, sender: 'user', created_at: pgTime(base + 3600001) });
  const user_favorites = Array.from({ length: users }, () => ({ id: uuid(r), user_id: pick(people), created_at: pgTime(now - Math.floor(r() * span)) }));
  const user_preferences = people.filter(() => r() < 0.7).map(user_id => ({ id: uuid(r), user_id,
    updated_at: r() < 0.1 ? null : pgTime(now - Math.floor(r() * span)),
    course_interest: r() < 0.2 ? null : Array.from({ length: Math.floor(r() * 4) }, () => r() < 0.05 ? null : pick(courses)),
    program_preference: r() < 0.2 ? null : pick(programs), location_preference: r() < 0.2 ? null : pick(cities) }));
  return { channel_links: links, user_attribution, user_profiles: profiles, chat_messages, user_favorites, user_preferences, campaigns, channels };
}

// ─── PostgREST simulado para a versão anterior ───────────────────────────────

const micros = value => { // ISO com até 6 casas → microssegundos (ordem/filtro como no Postgres)
  const m = /^(.*?)(?:\.(\d+))?([+-]\d\d:\d\d|Z)$/.exec(value);
  return BigInt(Date.parse(m[1] + m[3])) * 1000n + BigInt(((m[2] ?? '') + '000000').slice(3, 6));
};
const cmp = (a, b) => a === b ? 0 : a === null || a === undefined ? 1 : b === null || b === undefined ? -1 : a < b ? -1 : 1;

function restClient(data) {
  const tables = { ...data };
  return {
    auth: { getUser: async () => ({ data: { user: { id: 'admin' } }, error: null }),
      admin: { listUsers: async () => ({ data: { total: 1234, users: [] }, error: null }) } },
    rpc: async name => name === 'is_backoffice_admin' ? { data: true, error: null } : { data: null, error: { message: 'rpc inesperada ' + name } },
    from: table => {
      let rows = [...(tables[table] ?? [])], head = false, start = 0, end = Infinity, order = null, fields = null;
      const time = column => column === 'created_at' || column === 'updated_at';
      const q = {
        select: (f, options = {}) => { fields = f; head = !!options.head; return q; },
        eq: (c, v) => { rows = rows.filter(row => row[c] === v); return q; },
        gte: (c, v) => { rows = rows.filter(row => row[c] != null && (time(c) ? micros(row[c]) >= micros(v) : row[c] >= v)); return q; },
        lt: (c, v) => { rows = rows.filter(row => row[c] != null && (time(c) ? micros(row[c]) < micros(v) : row[c] < v)); return q; },
        not: (c, op, v) => { if (op !== 'is' || v !== null) throw new Error('not() inesperado'); rows = rows.filter(row => row[c] != null); return q; },
        order: (c, { ascending = true } = {}) => { order = [c, ascending]; return q; },
        range: (a, b) => { start = a; end = b; return q; },
        then: (ok, fail) => {
          if (order) rows.sort((x, y) => (order[1] ? 1 : -1) * cmp(x[order[0]], y[order[0]]));
          const cols = fields.split(',').map(s => s.trim()).filter(c => c !== '*');
          const shaped = rows.slice(start, end + 1).map(row => cols.length ? Object.fromEntries(cols.map(c => [c, row[c] ?? null])) : row);
          return Promise.resolve({ data: head ? null : shaped, count: rows.length, error: null }).then(ok, fail);
        },
      };
      return q;
    },
  };
}

// ─── Postgres embutido com a migration atual ────────────────────────────────

async function sqlClient(data) {
  const db = new PGlite();
  const migrations = resolve(root, 'supabase/migrations');
  const tp7 = readFileSync(resolve(migrations, '20261015202330_tp7_first_touch_attribution_filters.sql'), 'utf8');
  const migration = readdirSync(migrations).find(name => /_cc_attribution_sql_aggregates\.sql$/.test(name));
  await db.exec(`
    CREATE ROLE authenticated; CREATE ROLE anon; CREATE ROLE service_role; CREATE ROLE partner IN ROLE authenticated;
    CREATE SCHEMA auth;
    CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT 'service_role'::text $$;
    CREATE FUNCTION public.is_backoffice_admin() RETURNS boolean LANGUAGE sql AS $$ SELECT false $$;
    CREATE TABLE channel_links (id uuid PRIMARY KEY, campaign_id uuid, channel_id uuid NOT NULL, archived_at timestamptz);
    CREATE TABLE user_attribution (user_id uuid PRIMARY KEY, first_touch_link_id uuid, last_touch_link_id uuid);
    CREATE TABLE user_profiles (id uuid PRIMARY KEY, full_name text, city text);
    CREATE TABLE chat_messages (id uuid PRIMARY KEY, user_id uuid, sender text, created_at timestamptz);
    CREATE TABLE user_favorites (id uuid PRIMARY KEY, user_id uuid NOT NULL, created_at timestamptz NOT NULL);
    CREATE TABLE user_preferences (id uuid PRIMARY KEY, user_id uuid UNIQUE NOT NULL, updated_at timestamptz,
      course_interest text[], program_preference text, location_preference text);
  `);
  await db.exec(tp7.slice(0, tp7.indexOf('-- ─── get_students_paginated')));
  await db.exec(readFileSync(resolve(migrations, migration), 'utf8'));
  for (const table of ['channel_links', 'user_attribution', 'user_profiles', 'chat_messages', 'user_favorites', 'user_preferences']) {
    const rows = data[table] ?? [];
    for (let i = 0; i < rows.length; i += 500) {
      await db.query(`INSERT INTO public.${table} SELECT * FROM json_populate_recordset(NULL::public.${table}, $1::json)`,
        [JSON.stringify(rows.slice(i, i + 500))]);
    }
  }
  return {
    db,
    client: {
      ...restClient({}),
      from: table => { throw new Error('consulta direta a ' + table); },
      rpc: async (fn, params = {}) => {
        if (fn === 'is_backoffice_admin') return { data: true, error: null };
        const names = Object.keys(params);
        try {
          const result = await db.query(`SELECT public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')})::text AS r`, names.map(n => params[n]));
          return { data: JSON.parse(result.rows[0].r), error: null };
        } catch (error) {
          return { data: null, error: { message: error.message, code: error.code } };
        }
      },
    },
  };
}

// ─── células ─────────────────────────────────────────────────────────────────

function cells(data, now) {
  const firstLink = data.channel_links.find(link => link.campaign_id) ?? data.channel_links[0];
  const filters = [
    ['sem filtro', {}],
    ['campanha', firstLink?.campaign_id ? { campaignId: firstLink.campaign_id } : null],
    ['divulgador', firstLink ? { channelId: firstLink.channel_id } : null],
    ['campanha+divulgador', firstLink?.campaign_id ? { campaignId: firstLink.campaign_id, channelId: firstLink.channel_id } : null],
    ['sem atribuição', { unattributed: true }],
    ['campanha sem usuários', { campaignId: '00000000-0000-4000-8000-000000000000' }],
  ].filter(([, f]) => f);
  const day = 86400000, iso = ms => new Date(ms).toISOString();
  const ranges = [
    ['7d', { from: iso(now - 7 * day), to: iso(now) }],
    ['1d BRT', { from: '2026-10-16T03:00:00.000Z', to: '2026-10-17T03:00:00.000Z' }],
    ['30d', { from: iso(now - 30 * day), to: iso(now) }],
    ['virada de ano', { from: '2025-12-30T03:00:00.000Z', to: '2026-01-02T03:00:00.000Z' }],
  ];
  const out = [];
  for (const [fname, filter] of filters) {
    for (const [rname, dateRange] of [...ranges, ['sem período', undefined]]) {
      out.push(['analytics-stats', `${fname} · ${rname}`, { ...filter, ...(dateRange && { dateRange }) }]);
      out.push(['analytics-rankings', `users · ${fname} · ${rname}`, { type: 'users', ...filter, ...(dateRange && { dateRange }) }]);
      for (const timeZone of ['America/Sao_Paulo', 'UTC', 'Asia/Kolkata']) {
        for (const mode of ['week', 'day', 'total']) {
          if (!dateRange && timeZone === 'Asia/Kolkata' && mode === 'total') continue;
          out.push(['analytics-activity', `${mode} · ${timeZone} · ${fname} · ${rname}`, { mode, timeZone, ...filter, ...(dateRange && { dateRange }) }]);
        }
        out.push(['analytics-activity', `day zoom 13h · ${timeZone} · ${fname} · ${rname}`, { mode: 'day', zoomHour: 13, timeZone, ...filter, ...(dateRange && { dateRange }) }]);
      }
    }
    for (const type of ['locations', 'courses', 'preferences', 'location_preferences']) {
      out.push(['analytics-rankings', `${type} · ${fname}`, { type, ...filter }]);
    }
  }
  out.push(['analytics-stats', 'filtro incompatível', { unattributed: true, campaignId: firstLink?.campaign_id ?? data.channel_links[0]?.id }]);
  out.push(['analytics-activity', 'fuso inválido', { mode: 'week', timeZone: 'Mars/Olympus' }]);
  out.push(['analytics-rankings', 'tipo inválido', { type: 'nope' }]);
  out.push(['analytics-stats', 'período inválido', { dateRange: { from: 'x', to: 'y' } }]);
  return out;
}

// ─── execução ────────────────────────────────────────────────────────────────

const now = Date.now();
const data = args.data ? JSON.parse(readFileSync(resolve(args.data), 'utf8')) : synthetic(Number(args.seed ?? 93), Number(args.users ?? 300), now);
const { db, client: sql } = await sqlClient(data);
const rest = restClient(data);
const request = body => new Request('https://example.test', { method: 'POST', headers: { Authorization: 'Bearer differential' }, body: JSON.stringify(body) });
const handlers = Object.fromEntries(ENTRIES.map(entry => [entry, {
  before: loadEdge(entry, gitSource, rest),
  after: loadEdge(entry, workSource, sql),
}]));

const failures = [];
const all = cells(data, now);
for (const [entry, label, body] of all) {
  const before = await handlers[entry].before(request(body));
  const after = await handlers[entry].after(request(body));
  const [b, a] = [await before.text(), await after.text()];
  if (before.status !== after.status || b !== a) {
    const at = [...b].findIndex((c, i) => c !== a[i]);
    failures.push(`${entry} [${label}] status ${before.status}/${after.status} @${at}: antes=${b.slice(Math.max(0, at - 60), at + 80)} | depois=${a.slice(Math.max(0, at - 60), at + 80)}`);
  }
}
await db.close();
const sizes = Object.fromEntries(Object.entries(data).filter(([, v]) => Array.isArray(v) && v[0] && typeof v[0] === 'object').map(([k, v]) => [k, v.length]));
if (failures.length) {
  console.log(`DIFF_FAIL ${failures.length}/${all.length} células divergentes (dados: ${JSON.stringify(sizes)})`);
  for (const failure of failures.slice(0, 15)) console.log('  ✗ ' + failure);
  process.exit(1);
}
console.log(`DIFF_ALL_PASS ${all.length} células idênticas byte a byte (base ${BASE.slice(0, 8)}; dados: ${JSON.stringify(sizes)})`);
