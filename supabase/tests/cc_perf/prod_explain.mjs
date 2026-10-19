// NUB-RD-93 — medição SQL SOMENTE LEITURA (PROD ou DEV) das Edges analytics-*.
//
// Gera um único bloco DO que, para cada célula Edge × recorte, roda
// EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) N vezes, espaçadas:
//   antes  = os SELECTs que a Edge anterior manda ao PostgREST, sem paginação
//            (limite inferior: a Edge real fazia uma ida por página de 1000)
//   depois = o corpo das RPCs cc_*_aggregate desta migration, com os
//            parâmetros como literais (a RPC ainda não existe em PROD)
// e termina em RAISE EXCEPTION 'CC_PERF {json}' — nenhum objeto é criado e nada
// é escrito. Roda num conector/sessão read-only. Mede tempo de SQL, NÃO o p95
// ponta a ponta da Edge (rede, PostgREST e Deno ficam de fora).
//
//   node supabase/tests/cc_perf/prod_explain.mjs --edge stats --campaign <uuid> --channel <uuid> [--n 5] [--to 2026-10-19T17:00:00Z] [--only 'sem atribuição']
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, v, i, all) =>
  v.startsWith('--') ? [...acc, [v.slice(2), all[i + 1]]] : acc, []));
const N = Number(args.n ?? 5);
const to = new Date(args.to ?? new Date(Math.floor(Date.now() / 3600000) * 3600000).toISOString());
const from = new Date(to.getTime() - 7 * 86400000), prev = new Date(from.getTime() - 7 * 86400000);
const lit = d => `'${d.toISOString()}'::timestamptz`;
const migrations = resolve(root, 'supabase/migrations');
const migration = readFileSync(resolve(migrations, readdirSync(migrations).find(n => /_cc_attribution_sql_aggregates\.sql$/.test(n))), 'utf8')
  .replace(/\r\n/g, '\n');

// Corpo de cada SELECT ... INTO v_result das funções, na ordem do arquivo.
function bodies(fn) {
  const start = migration.indexOf(`CREATE FUNCTION public.${fn}(`);
  const end = migration.indexOf('$$;', start);
  const text = migration.slice(start, end);
  return [...text.matchAll(/(WITH allowed AS MATERIALIZED[\s\S]*?)INTO v_result([\s\S]*?);\n/g)].map(m => m[1] + m[2]);
}
const substitute = (sql, values) => Object.entries(values).reduce(
  (acc, [name, value]) => acc.replace(new RegExp(`\\b${name}\\b`, 'g'), value), sql).replace(/--[^\n]*/g, '');

const FILTERS = {
  campanha: { campaign: args.campaign, channel: null, unattributed: null },
  divulgador: { campaign: null, channel: args.channel, unattributed: null },
  'sem atribuição': { campaign: null, channel: null, unattributed: true },
  'sem filtro': { campaign: null, channel: null, unattributed: null },
};
const filterValues = f => ({
  p_filter_campaign_id: f.campaign ? `'${f.campaign}'::uuid` : 'NULL::uuid',
  p_filter_channel_id: f.channel ? `'${f.channel}'::uuid` : 'NULL::uuid',
  p_filter_unattributed: f.unattributed ? 'true' : 'NULL::boolean',
  v_filtered: f.campaign || f.channel || f.unattributed ? 'true' : 'false',
});

// SELECTs da Edge anterior (o que resolveAttributedUserIds + fetchRows pediam).
const rest = (select, where = 'true', order = 'id') => `SELECT json_agg(t) FROM (SELECT ${select} WHERE ${where} ORDER BY ${order}) t`;
function resolveQueries(f) {
  if (f.unattributed) return [
    rest('user_id, first_touch_link_id FROM public.user_attribution', 'first_touch_link_id IS NOT NULL', 'user_id'),
    rest('id FROM public.user_profiles'),
  ];
  if (f.campaign || f.channel) return [
    rest('id FROM public.channel_links', [f.campaign && `campaign_id = '${f.campaign}'`, f.channel && `channel_id = '${f.channel}'`].filter(Boolean).join(' AND ')),
    rest('user_id, first_touch_link_id FROM public.user_attribution', 'first_touch_link_id IS NOT NULL', 'user_id'),
  ];
  return [];
}
const window = (start, end, column = 'created_at') => `sender = 'user' AND ${column} >= ${lit(start)} AND ${column} < ${lit(end)}`;
const OLD = {
  stats: f => [...resolveQueries(f),
    rest('user_id, created_at FROM public.chat_messages', window(prev, to)),
    rest('user_id, created_at FROM public.user_favorites'),
    rest('user_id, updated_at FROM public.user_preferences', `updated_at >= ${lit(prev)} AND updated_at < ${lit(to)}`),
    rest('id, full_name FROM public.user_profiles'),
    ...(f.campaign || f.channel || f.unattributed ? [] : [
      `SELECT count(*) FROM public.chat_messages WHERE ${window(from, to)}`,
      `SELECT count(*) FROM public.chat_messages WHERE ${window(prev, from)}`,
    ])],
  activity: f => [...resolveQueries(f), rest('user_id, created_at FROM public.chat_messages', window(from, to))],
  rankings: f => [...resolveQueries(f), rest('user_id, created_at FROM public.chat_messages', window(from, to)),
    rest('id, full_name FROM public.user_profiles'), rest('user_id FROM public.user_favorites')],
};
const NEW = {
  stats: f => substitute(bodies('cc_stats_aggregate')[0], { ...filterValues(f),
    p_from: lit(from), p_to: lit(to), p_prev_from: lit(prev), p_with_history: 'false' }),
  activity: f => substitute(bodies('cc_activity_aggregate')[0], { ...filterValues(f),
    p_mode: `'week'`, p_from: lit(from), p_to: lit(to), v_tz: `'America/Sao_Paulo'`, v_ranged: 'true', v_zoom: 'NULL::int',
    p_zoom_hour: 'NULL::int', v_now: 'now()', v_today: `(now() AT TIME ZONE 'America/Sao_Paulo')::date`,
    v_start: `((now() AT TIME ZONE 'America/Sao_Paulo')::date - 6)` }),
  rankings: f => substitute(bodies('cc_rankings_aggregate')[0], { ...filterValues(f), p_from: lit(from), p_to: lit(to) }),
};

const edge = args.edge;
if (!OLD[edge]) throw new Error('--edge stats|activity|rankings');
const cells = Object.entries(FILTERS).filter(([name, f]) => !(f.campaign === undefined || f.channel === undefined)
  && (!args.only || args.only === name)).map(([name, f]) => ({
  name, old: OLD[edge](f), new: NEW[edge](f),
}));
const q = s => '$q$' + s + '$q$';
console.log(`DO $perf$
DECLARE
  cells jsonb := '[]';
  r jsonb; plan jsonb; t numeric; hit bigint; rd bigint; rows bigint; i int; k int;
  old_q text[]; new_q text; name text; series jsonb; old_total numeric; old_pages int;
BEGIN
${cells.map(c => `  name := ${q(c.name)};
  old_q := ARRAY[${c.old.map(q).join(', ')}]::text[];
  new_q := ${q(c.new)};
  series := '[]';
  FOR i IN 1..${N + 1} LOOP
    old_total := 0; old_pages := 0; hit := 0; rd := 0;
    FOR k IN 1..array_length(old_q, 1) LOOP
      EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || old_q[k] INTO plan;
      old_total := old_total + (plan->0->>'Execution Time')::numeric + (plan->0->>'Planning Time')::numeric;
      rows := coalesce((plan->0->'Plan'->'Plans'->0->>'Actual Rows')::bigint, (plan->0->'Plan'->>'Actual Rows')::bigint, 0);
      old_pages := old_pages + CASE WHEN old_q[k] LIKE 'SELECT count%' THEN 1 ELSE greatest(1, ceil(rows / 1000.0)::int) END;
      hit := hit + coalesce((plan->0->'Plan'->>'Shared Hit Blocks')::bigint, 0);
      rd := rd + coalesce((plan->0->'Plan'->>'Shared Read Blocks')::bigint, 0);
    END LOOP;
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || new_q INTO plan;
    series := series || jsonb_build_object('i', i, 'old_ms', round(old_total, 2), 'old_requests', old_pages,
      'old_hit', hit, 'old_read', rd,
      'new_ms', round((plan->0->>'Execution Time')::numeric + (plan->0->>'Planning Time')::numeric, 2),
      'new_hit', (plan->0->'Plan'->>'Shared Hit Blocks')::bigint, 'new_read', (plan->0->'Plan'->>'Shared Read Blocks')::bigint);
    PERFORM pg_sleep(0.2);
  END LOOP;
  cells := cells || jsonb_build_object('cell', name, 'old_queries', array_length(old_q, 1), 'series', series);
`).join('')}
  RAISE EXCEPTION 'CC_PERF %', jsonb_build_object('edge', ${q(edge)}, 'n_warm', ${N}, 'from', ${q(from.toISOString())}, 'to', ${q(to.toISOString())}, 'cells', cells)::text;
END
$perf$;`);
