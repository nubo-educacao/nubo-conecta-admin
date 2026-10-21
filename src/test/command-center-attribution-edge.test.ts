// @vitest-environment node
// Filtros de campanha/divulgador (first-touch) nas Edge Functions do Command
// Center. Mesmo contrato das RPCs (TP-7): first_touch_link_id → channel_links;
// last touch não conta; "sem atribuição" = perfil sem linha ou first-touch nulo.
// NUB-RD-93: o recorte é feito em SQL (cc_*_aggregate). Cada Edge faz uma única
// chamada RPC, executada aqui no PGlite com a migration real; os valores
// esperados são os mesmos de quando o recorte era feito em memória.
import {
  parseAttributionFilter,
  attributionRpcArgs,
  isAttributionFilterError,
} from '../../supabase/functions/_shared/attribution-filter';
import { edgeHarness, edgeRequest } from './edgeHarness';
import { aggregatesDb, aggregatesClient, type Tables } from './ccAggregatesDb';
import type { PGlite } from '@electric-sql/pglite';

const CAMPAIGN_A = 'aaaaaaaa-0000-4000-8000-00000000000a';
const CAMPAIGN_B = 'aaaaaaaa-0000-4000-8000-00000000000b';
const CHANNEL_X = 'bbbbbbbb-0000-4000-8000-00000000000e';
const CHANNEL_Y = 'bbbbbbbb-0000-4000-8000-00000000000f';
const U = { a: 'cccccccc-0000-4000-8000-00000000000a', b: 'cccccccc-0000-4000-8000-00000000000b', c: 'cccccccc-0000-4000-8000-00000000000c',
  d: 'cccccccc-0000-4000-8000-00000000000d', e: 'cccccccc-0000-4000-8000-00000000000e' };
const L1 = 'dddddddd-0000-4000-8000-000000000001', L2 = 'dddddddd-0000-4000-8000-000000000002', L3 = 'dddddddd-0000-4000-8000-000000000003';

const range = { from: '2026-06-15T03:00:00.000Z', to: '2026-06-16T03:00:00.000Z' };
const at = (minute: number) => new Date(Date.parse(range.from) + minute * 60000).toISOString();

// a: first l1 (A,X) · b: first l2 (B,X), last l1 · c: linha sem first-touch · d: sem linha
// l3 (A,Y) arquivado: e chegou por ele e continua contando.
const tables: Tables = {
  channel_links: [
    { id: L1, campaign_id: CAMPAIGN_A, channel_id: CHANNEL_X, archived_at: null },
    { id: L2, campaign_id: CAMPAIGN_B, channel_id: CHANNEL_X, archived_at: null },
    { id: L3, campaign_id: CAMPAIGN_A, channel_id: CHANNEL_Y, archived_at: '2026-01-01T00:00:00Z' },
  ],
  user_attribution: [
    { user_id: U.a, first_touch_link_id: L1, last_touch_link_id: L1 },
    { user_id: U.b, first_touch_link_id: L2, last_touch_link_id: L1 },
    { user_id: U.c, first_touch_link_id: null, last_touch_link_id: L1 },
    { user_id: U.e, first_touch_link_id: L3, last_touch_link_id: L3 },
  ],
  user_profiles: (['a', 'b', 'c', 'd', 'e'] as const).map(k => ({ id: U[k], full_name: k.toUpperCase(), city: k === 'a' ? 'Recife - PE' : 'Natal' })),
  chat_messages: [
    ...[0, 5, 40].map(minute => ({ user_id: U.a, sender: 'user', created_at: at(minute) })),
    ...[1, 2].map(minute => ({ user_id: U.b, sender: 'user', created_at: at(minute) })),
    { user_id: U.d, sender: 'user', created_at: at(3) },
    { user_id: null, sender: 'user', created_at: at(4) },
    { user_id: U.c, sender: 'system', created_at: at(5) },
  ],
  user_favorites: [
    ...Array.from({ length: 4 }, () => ({ user_id: U.b, created_at: range.from })),
    { user_id: U.d, created_at: range.from },
  ],
  user_preferences: [
    { id: 'eeeeeeee-0000-4000-8000-000000000001', user_id: U.a, updated_at: at(10), course_interest: ['Direito'], program_preference: 'sisu', location_preference: 'Recife' },
    { id: 'eeeeeeee-0000-4000-8000-000000000002', user_id: U.b, updated_at: at(10), course_interest: ['Medicina'], program_preference: 'prouni', location_preference: 'Natal' },
    { id: 'eeeeeeee-0000-4000-8000-000000000003', user_id: U.d, updated_at: at(10), course_interest: ['Medicina'], program_preference: 'prouni', location_preference: 'Natal' },
  ],
};

let db: PGlite;
beforeAll(async () => { db = await aggregatesDb(tables); });
afterAll(async () => { await db?.close(); });

describe('parseAttributionFilter', () => {
  it.each([undefined, null, {}, { dateRange: range }, { unattributed: false },
    { campaignId: null, channelId: null, unattributed: null }])('sem filtro ativo → null: %j', (body) => {
    expect(parseAttributionFilter(body)).toBeNull();
  });
  it('lê campanha, divulgador e "sem atribuição" do corpo', () => {
    expect(parseAttributionFilter({ type: 'users', campaignId: CAMPAIGN_A })).toEqual({ campaignId: CAMPAIGN_A });
    expect(parseAttributionFilter({ campaignId: CAMPAIGN_A, channelId: CHANNEL_X })).toEqual({ campaignId: CAMPAIGN_A, channelId: CHANNEL_X });
    expect(parseAttributionFilter({ channelId: CHANNEL_X.toUpperCase() })).toEqual({ channelId: CHANNEL_X.toUpperCase() });
    expect(parseAttributionFilter({ unattributed: true })).toEqual({ unattributed: true });
  });
  it.each([
    { campaignId: 'insper' }, { channelId: 42 }, { campaignId: '' }, { unattributed: 'true' },
    { unattributed: true, campaignId: CAMPAIGN_A }, { unattributed: true, channelId: CHANNEL_X },
  ])('recusa filtro inválido ou combinação exclusiva: %j', (body) => {
    let error: unknown;
    try { parseAttributionFilter(body); } catch (e) { error = e; }
    expect(isAttributionFilterError(error)).toBe(true);
  });
});

describe('attributionRpcArgs', () => {
  it('sem filtro manda os três parâmetros nulos; com filtro, só o que veio', () => {
    expect(attributionRpcArgs(null)).toEqual({ p_filter_campaign_id: null, p_filter_channel_id: null, p_filter_unattributed: null });
    expect(attributionRpcArgs({ campaignId: CAMPAIGN_A, channelId: CHANNEL_X }))
      .toEqual({ p_filter_campaign_id: CAMPAIGN_A, p_filter_channel_id: CHANNEL_X, p_filter_unattributed: null });
    expect(attributionRpcArgs({ unattributed: true }))
      .toEqual({ p_filter_campaign_id: null, p_filter_channel_id: null, p_filter_unattributed: true });
  });
});

const call = async (entry: string, body: Record<string, unknown>) => {
  const { client, rpcCalls, tableCalls } = aggregatesClient(db);
  const response = await edgeHarness('supabase/functions/' + entry + '/index.ts', client).handler(edgeRequest(body));
  return { response, json: await response.json(), rpcCalls, tableCalls, listUsers: client.auth.admin.listUsers };
};

describe('uma única RPC por chamada, sem paginar tabelas', () => {
  it.each([
    ['analytics-stats', 'cc_stats_aggregate', { dateRange: range, campaignId: CAMPAIGN_A }],
    ['analytics-stats', 'cc_stats_aggregate', { dateRange: range }],
    ['analytics-activity', 'cc_activity_aggregate', { mode: 'week', dateRange: range, channelId: CHANNEL_X }],
    ['analytics-rankings', 'cc_rankings_aggregate', { type: 'users', dateRange: range, unattributed: true }],
    ['analytics-rankings', 'cc_rankings_aggregate', { type: 'locations', campaignId: CAMPAIGN_A }],
  ])('%s → %s', async (entry, fn, body) => {
    const { response, rpcCalls, tableCalls } = await call(entry, body);
    expect(response.status).toBe(200);
    expect(rpcCalls.map(c => c.fn)).toEqual([fn]);
    expect(tableCalls).toEqual([]);
  });
  it('repassa o recorte e o período à RPC', async () => {
    const { rpcCalls } = await call('analytics-stats', { dateRange: range, campaignId: CAMPAIGN_A, channelId: CHANNEL_X });
    expect(rpcCalls[0].args).toEqual({
      p_from: range.from, p_to: range.to, p_prev_from: '2026-06-14T03:00:00.000Z', p_with_history: false,
      p_filter_campaign_id: CAMPAIGN_A, p_filter_channel_id: CHANNEL_X, p_filter_unattributed: null,
    });
  });
});

describe('analytics-stats com recorte', () => {
  it('sem filtro mantém o comportamento: auth.admin.listUsers para o total de cadastros', async () => {
    const { json, listUsers } = await call('analytics-stats', { dateRange: range });
    expect(listUsers).toHaveBeenCalled();
    expect(json).toMatchObject({ totalRegistered: 50, totalMessages: 7, activeUsersWithMessages: 3, totalFavorites: 5 });
  });
  it('campanha: cadastros, mensagens, ativos, recorrentes e favoritos só de quem chegou por ela', async () => {
    const { response, json, listUsers } = await call('analytics-stats', { dateRange: range, campaignId: CAMPAIGN_A });
    expect(response.status).toBe(200);
    expect(listUsers).not.toHaveBeenCalled();
    expect(json).toMatchObject({
      totalRegistered: 2, totalMessages: 3, activeUsersWithMessages: 1, catalogUsers: 0, activeUsers: 1,
      powerUsers: 1, totalFavorites: 0,
    });
    expect(json.powerUsersList).toEqual([{ userId: U.a, userName: 'A', userPhone: '', accessCount: 2 }]);
  });
  it('divulgador: favoritos e usuários de catálogo do recorte', async () => {
    const { json } = await call('analytics-stats', { dateRange: range, channelId: CHANNEL_X });
    expect(json).toMatchObject({ totalRegistered: 2, totalMessages: 5, activeUsersWithMessages: 2, totalFavorites: 4 });
  });
  it('"sem atribuição": mensagens anônimas e de sistema não entram', async () => {
    const { json } = await call('analytics-stats', { dateRange: range, unattributed: true });
    expect(json).toMatchObject({ totalRegistered: 2, totalMessages: 1, activeUsersWithMessages: 1, catalogUsers: 0, totalFavorites: 1 });
  });
  it('sem período, o total de mensagens com recorte é o histórico do recorte', async () => {
    const { json, rpcCalls } = await call('analytics-stats', { campaignId: CAMPAIGN_A });
    expect(json.totalMessages).toBe(3);
    expect(rpcCalls[0].args.p_with_history).toBe(true);
  });
  it('filtro inválido → 400 com a mesma mensagem, antes de qualquer RPC', async () => {
    const incompatible = await call('analytics-stats', { dateRange: range, unattributed: true, campaignId: CAMPAIGN_A });
    expect(incompatible.response.status).toBe(400);
    expect(incompatible.json.error).toBe('Filtro de atribuição incompatível: "sem atribuição" não combina com campanha/divulgador');
    expect(incompatible.rpcCalls).toEqual([]);
    expect((await call('analytics-stats', { dateRange: range, campaignId: 'x' })).response.status).toBe(400);
  });
});

describe('analytics-activity com recorte', () => {
  it('conta só mensagens e usuários do recorte', async () => {
    const base = await call('analytics-activity', { mode: 'week', dateRange: range, timeZone: 'America/Sao_Paulo' });
    expect(base.json).toEqual([{ label: '15/06', mensagens: 7, usuarios: 3 }]);
    const filtered = await call('analytics-activity', { mode: 'week', dateRange: range, timeZone: 'America/Sao_Paulo', channelId: CHANNEL_X });
    expect(filtered.json).toEqual([{ label: '15/06', mensagens: 5, usuarios: 2 }]);
  });
  it('filtro inválido → 400', async () => {
    expect((await call('analytics-activity', { mode: 'week', dateRange: range, unattributed: true, channelId: CHANNEL_X })).response.status).toBe(400);
  });
});

describe('analytics-rankings com recorte', () => {
  it('users: ranking só do recorte', async () => {
    const { json } = await call('analytics-rankings', { type: 'users', dateRange: range, campaignId: CAMPAIGN_A });
    expect(json.map((u: any) => [u.id, u.messages])).toEqual([[U.a, 3]]);
  });
  it('courses, preferences, location_preferences e locations recortados; sem filtro, inalterados', async () => {
    expect((await call('analytics-rankings', { type: 'courses' })).json).toEqual([{ name: 'Medicina', searches: 2 }, { name: 'Direito', searches: 1 }]);
    expect((await call('analytics-rankings', { type: 'courses', campaignId: CAMPAIGN_A })).json).toEqual([{ name: 'Direito', searches: 1 }]);
    expect((await call('analytics-rankings', { type: 'preferences', channelId: CHANNEL_X })).json)
      .toEqual([{ name: 'sisu', value: 50 }, { name: 'prouni', value: 50 }]);
    expect((await call('analytics-rankings', { type: 'location_preferences', unattributed: true })).json).toEqual([{ name: 'Natal', count: 1 }]);
    expect((await call('analytics-rankings', { type: 'locations' })).json).toEqual([{ name: 'Natal', count: 4 }, { name: 'Recife', count: 1 }]);
    expect((await call('analytics-rankings', { type: 'locations', campaignId: CAMPAIGN_A })).json)
      .toEqual([{ name: 'Recife', count: 1 }, { name: 'Natal', count: 1 }]);
  });
  it('filtro inválido → 400', async () => {
    expect((await call('analytics-rankings', { type: 'courses', campaignId: 'nope' })).response.status).toBe(400);
  });
});
