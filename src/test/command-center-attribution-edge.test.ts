// Filtros de campanha/divulgador (first-touch) nas Edge Functions do Command
// Center. Mesmo contrato das RPCs (TP-7): first_touch_link_id → channel_links;
// last touch não conta; "sem atribuição" = sem linha ou first-touch nulo.
import {
  parseAttributionFilter,
  resolveAttributedUserIds,
  keepAllowed,
  isAttributionFilterError,
} from '../../supabase/functions/_shared/attribution-filter';
import { edgeHarness, testDatabase, edgeRequest } from './edgeHarness';

const CAMPAIGN_A = 'aaaaaaaa-0000-4000-8000-00000000000a';
const CAMPAIGN_B = 'aaaaaaaa-0000-4000-8000-00000000000b';
const CHANNEL_X = 'bbbbbbbb-0000-4000-8000-00000000000e';
const CHANNEL_Y = 'bbbbbbbb-0000-4000-8000-00000000000f';

const range = { from: '2026-06-15T03:00:00.000Z', to: '2026-06-16T03:00:00.000Z' };
const at = (minute: number) => new Date(Date.parse(range.from) + minute * 60000).toISOString();

// a: first l1 (A,X) · b: first l2 (B,X), last l1 · c: linha sem first-touch · d: sem linha
// l3 (A,Y) arquivado: e chegou por ele e continua contando.
const attributionTables = {
  channel_links: [
    { id: 'l1', campaign_id: CAMPAIGN_A, channel_id: CHANNEL_X, archived_at: null },
    { id: 'l2', campaign_id: CAMPAIGN_B, channel_id: CHANNEL_X, archived_at: null },
    { id: 'l3', campaign_id: CAMPAIGN_A, channel_id: CHANNEL_Y, archived_at: '2026-01-01T00:00:00Z' },
  ],
  user_attribution: [
    { user_id: 'a', first_touch_link_id: 'l1', last_touch_link_id: 'l1' },
    { user_id: 'b', first_touch_link_id: 'l2', last_touch_link_id: 'l1' },
    { user_id: 'c', first_touch_link_id: null, last_touch_link_id: 'l1' },
    { user_id: 'e', first_touch_link_id: 'l3', last_touch_link_id: 'l3' },
  ],
  user_profiles: ['a', 'b', 'c', 'd', 'e'].map(id => ({ id, full_name: id.toUpperCase(), city: id === 'a' ? 'Recife - PE' : 'Natal' })),
};

const tables = {
  ...attributionTables,
  chat_messages: [
    ...[0, 5, 40].map(minute => ({ user_id: 'a', sender: 'user', created_at: at(minute) })),
    ...[1, 2].map(minute => ({ user_id: 'b', sender: 'user', created_at: at(minute) })),
    { user_id: 'd', sender: 'user', created_at: at(3) },
    { user_id: null, sender: 'user', created_at: at(4) },
    { user_id: 'c', sender: 'system', created_at: at(5) },
  ],
  user_favorites: [
    ...Array.from({ length: 4 }, () => ({ user_id: 'b', created_at: range.from })),
    { user_id: 'd', created_at: range.from },
  ],
  user_preferences: [
    { id: 1, user_id: 'a', updated_at: at(10), course_interest: ['Direito'], program_preference: 'sisu', location_preference: 'Recife' },
    { id: 2, user_id: 'b', updated_at: at(10), course_interest: ['Medicina'], program_preference: 'prouni', location_preference: 'Natal' },
    { id: 3, user_id: 'd', updated_at: at(10), course_interest: ['Medicina'], program_preference: 'prouni', location_preference: 'Natal' },
  ],
  agent_errors: [],
};

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

describe('resolveAttributedUserIds', () => {
  const resolve = async (filter: Parameters<typeof resolveAttributedUserIds>[1], data: Record<string, any[]> = attributionTables) => {
    const db = testDatabase(data);
    const ids = await resolveAttributedUserIds(db.client, filter);
    return { ids: ids && [...ids].sort(), calls: db.calls };
  };
  it('sem filtro não consulta nada', async () => {
    expect(await resolve(null)).toEqual({ ids: null, calls: [] });
  });
  it('campanha pelo first-touch, inclusive link arquivado; last-touch não conta', async () => {
    expect((await resolve({ campaignId: CAMPAIGN_A })).ids).toEqual(['a', 'e']);
    expect((await resolve({ campaignId: CAMPAIGN_B })).ids).toEqual(['b']);
  });
  it('divulgador e combinação (AND no mesmo link)', async () => {
    expect((await resolve({ channelId: CHANNEL_X })).ids).toEqual(['a', 'b']);
    expect((await resolve({ campaignId: CAMPAIGN_A, channelId: CHANNEL_X })).ids).toEqual(['a']);
    expect((await resolve({ campaignId: CAMPAIGN_B, channelId: CHANNEL_Y })).ids).toEqual([]);
  });
  it('"sem atribuição" = perfis sem linha ou com first-touch nulo', async () => {
    expect((await resolve({ unattributed: true })).ids).toEqual(['c', 'd']);
  });
  it('pagina user_attribution além do limite do PostgREST', async () => {
    const many = Array.from({ length: 1003 }, (_, i) => ({ user_id: 'u' + i, first_touch_link_id: 'l1' }));
    const { ids, calls } = await resolve({ campaignId: CAMPAIGN_A }, { ...attributionTables, user_attribution: many });
    expect(ids).toHaveLength(1003);
    expect(calls.filter(call => call.table === 'user_attribution')).toHaveLength(2);
  });
  it('falha da fonte vira erro, nunca um recorte vazio', async () => {
    const db = testDatabase(attributionTables, { user_attribution: 'source unavailable' });
    await expect(resolveAttributedUserIds(db.client, { campaignId: CAMPAIGN_A })).rejects.toThrow('source unavailable');
  });
});

describe('keepAllowed', () => {
  it('sem filtro devolve as mesmas linhas; com filtro descarta ids fora do recorte e nulos', () => {
    const rows = [{ user_id: 'a' }, { user_id: null }, { user_id: 'b' }];
    expect(keepAllowed(rows, null, 'user_id')).toBe(rows);
    expect(keepAllowed(rows, new Set(['b']), 'user_id')).toEqual([{ user_id: 'b' }]);
  });
});

const call = async (entry: string, body: Record<string, unknown>, data: Record<string, any[]> = tables) => {
  const db = testDatabase(data);
  const listUsers = vi.fn(db.client.auth.admin.listUsers);
  db.client.auth.admin.listUsers = listUsers;
  const response = await edgeHarness('supabase/functions/' + entry + '/index.ts', db.client).handler(edgeRequest(body));
  return { response, json: await response.json(), calls: db.calls, listUsers };
};
const attributionCalls = (calls: { table: string }[]) =>
  calls.filter(c => c.table === 'user_attribution' || c.table === 'channel_links');

describe('analytics-stats com recorte', () => {
  it('sem filtro mantém o comportamento: auth.admin.listUsers e nenhuma consulta de atribuição', async () => {
    const { json, calls, listUsers } = await call('analytics-stats', { dateRange: range });
    expect(listUsers).toHaveBeenCalled();
    expect(json).toMatchObject({ totalRegistered: 50, totalMessages: 7, activeUsersWithMessages: 3, totalFavorites: 5 });
    expect(attributionCalls(calls)).toEqual([]);
  });
  it('campanha: cadastros, mensagens, ativos, recorrentes e favoritos só de quem chegou por ela', async () => {
    const { response, json, listUsers } = await call('analytics-stats', { dateRange: range, campaignId: CAMPAIGN_A });
    expect(response.status).toBe(200);
    expect(listUsers).not.toHaveBeenCalled();
    expect(json).toMatchObject({
      totalRegistered: 2, totalMessages: 3, activeUsersWithMessages: 1, catalogUsers: 0, activeUsers: 1,
      powerUsers: 1, totalFavorites: 0,
    });
    expect(json.powerUsersList.map((u: any) => u.userId)).toEqual(['a']);
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
    const { json } = await call('analytics-stats', { campaignId: CAMPAIGN_A });
    expect(json.totalMessages).toBe(3);
  });
  it('filtro inválido → 400', async () => {
    expect((await call('analytics-stats', { dateRange: range, unattributed: true, campaignId: CAMPAIGN_A })).response.status).toBe(400);
    expect((await call('analytics-stats', { dateRange: range, campaignId: 'x' })).response.status).toBe(400);
  });
});

describe('analytics-activity com recorte', () => {
  it('conta só mensagens e usuários do recorte', async () => {
    const base = await call('analytics-activity', { mode: 'week', dateRange: range, timeZone: 'America/Sao_Paulo' });
    expect(base.json).toEqual([{ label: '15/06', mensagens: 7, usuarios: 3 }]);
    expect(attributionCalls(base.calls)).toEqual([]);
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
    expect(json.map((u: any) => [u.id, u.messages])).toEqual([['a', 3]]);
  });
  it('courses, preferences, location_preferences e locations recortados; sem filtro, inalterados', async () => {
    const base = await call('analytics-rankings', { type: 'courses' });
    expect(base.json).toEqual([{ name: 'Medicina', searches: 2 }, { name: 'Direito', searches: 1 }]);
    expect(attributionCalls(base.calls)).toEqual([]);
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
