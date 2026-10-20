// @vitest-environment node
// Métricas do Command Center (analytics-stats/activity/rankings). NUB-RD-93: as
// Edges delegam a agregação às RPCs cc_*_aggregate, executadas aqui no PGlite
// com a migration real; os valores esperados são os de antes da mudança.
import { edgeHarness, edgeRequest } from './edgeHarness';
import type { PGlite } from '@electric-sql/pglite';
import { aggregatesDb, aggregatesClient, seedAggregates, type Tables } from './ccAggregatesDb';

const range = { from: '2026-06-15T03:00:00.000Z', to: '2026-06-16T03:00:00.000Z' };
const A = 'cccccccc-0000-4000-8000-00000000000a', B = 'cccccccc-0000-4000-8000-00000000000b', C = 'cccccccc-0000-4000-8000-00000000000c';
const messages = [
  ...[0, 5, 40].map(minute => ({ user_id: A, sender: 'user', created_at: new Date(Date.parse(range.from) + minute * 60000).toISOString() })),
  ...[1, 2].map(minute => ({ user_id: B, sender: 'user', created_at: new Date(Date.parse(range.from) + minute * 60000).toISOString() })),
  { user_id: C, sender: 'system', created_at: range.from },
  { user_id: A, sender: 'cloudinha', created_at: range.from },
  { user_id: A, sender: 'user', created_at: range.to },
  { user_id: B, sender: 'user', created_at: '2026-06-14T12:00:00.000Z' },
];
const tables: Tables = { chat_messages: messages,
  user_profiles: [A, B, C].map(id => ({ id, full_name: id.slice(-1) })),
  user_favorites: Array.from({ length: 20 }, () => ({ user_id: B, created_at: range.from })),
};

// Uma única instância PGlite por arquivo; cada `run` só troca as linhas das tabelas.
// Subir uma instância por chamada (38 vezes aqui, 4 num único `it`) estourava o timeout
// de 5 s no runner de CI de 2 vCPUs quando outros arquivos PGlite rodavam em paralelo.
let sharedDb: PGlite;
beforeAll(async () => { sharedDb = await aggregatesDb({}); }, 60000);
afterAll(async () => { await sharedDb?.close(); });

async function run(entry: string, body: unknown, data: Tables = tables, options: { admin?: boolean; failRpc?: string } = {}) {
  await seedAggregates(sharedDb, data);
  const { client, rpcCalls, tableCalls } = aggregatesClient(sharedDb, { admin: options.admin ?? true });
  if (options.failRpc) client.rpc = async (fn: string) => fn === 'is_backoffice_admin'
    ? { data: true, error: null } : { data: null, error: { message: options.failRpc } };
  const app = edgeHarness('supabase/functions/' + entry + '/index.ts', client);
  const request = typeof body === 'string'
    ? new Request('https://example.test', { method: 'POST', headers: { Authorization: 'Bearer test-only' }, body })
    : edgeRequest(body);
  const response = await app.handler(request);
  return { response, text: await response.text(), rpcCalls, tableCalls, createClient: app.createClient };
}
const json = (result: { text: string }) => JSON.parse(result.text);

describe('Command Center message rankings', () => {
  it('ranks by user-message count, not favorites; excludes zero senders and other periods', async () => {
    const result = await run('analytics-rankings', { type: 'users', dateRange: range });
    expect(result.response.status).toBe(200);
    expect(json(result).map((user: any) => [user.id, user.messages, user.sessions])).toEqual([[A, 3, 2], [B, 2, 1]]);
    expect(json(result)[1]).toEqual({ id: B, name: 'b', messages: 2, favorites: 20, sessions: 1, score: 2 });
  });
  it('returns an empty ranking instead of listing every registered profile', async () => {
    expect((await run('analytics-rankings', { type: 'users', dateRange: range }, { ...tables, chat_messages: [] })).text).toBe('[]');
  });
  it('propagates source failure instead of returning an apparently successful empty ranking', async () => {
    expect((await run('analytics-rankings', { type: 'users', dateRange: range }, tables, { failRpc: 'source unavailable' })).response.status).toBe(500);
  });
  it('normalizes and breaks ties by first appearance in id order, as before', async () => {
    const p = (n: number) => `ffffffff-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;
    const data: Tables = {
      user_profiles: [
        { id: p(1), city: 'RIO  de janeiro' }, { id: p(2), city: 'são paulo - sp' }, { id: p(3), city: 'São Paulo' },
        { id: p(4), city: 'Natal - RN' }, { id: p(5), city: ' - RN' }, { id: p(6), city: null }, { id: p(7), city: 'ÉVORA' },
      ],
      user_preferences: [
        { id: p(1), user_id: p(1), course_interest: ['medicina', 'Direito', 'medicina'], program_preference: 'sisu', location_preference: 'recife - pe' },
        { id: p(2), user_id: p(2), course_interest: ['  ', 'DIREITO', null], program_preference: 'sisu', location_preference: 'Natal' },
        { id: p(3), user_id: p(3), course_interest: [], program_preference: 'prouni', location_preference: '' },
        { id: p(4), user_id: p(4), course_interest: null, program_preference: '', location_preference: null },
      ],
    };
    const ranking = async (type: string) => json(await run('analytics-rankings', { type }, data));
    expect(await ranking('locations')).toEqual([
      { name: 'São Paulo', count: 2 }, { name: 'Rio  De Janeiro', count: 1 }, { name: 'Natal', count: 1 }, { name: 'Évora', count: 1 },
    ]);
    expect(await ranking('courses')).toEqual([{ name: 'Medicina', searches: 2 }, { name: 'Direito', searches: 2 }]);
    expect(await ranking('preferences')).toEqual([{ name: 'sisu', value: 50 }, { name: 'prouni', value: 25 }]);
    expect(await ranking('location_preferences')).toEqual([{ name: 'Recife', count: 1 }, { name: 'Natal', count: 1 }]);
  });
  it('rejects an unknown ranking type without querying', async () => {
    const result = await run('analytics-rankings', { type: 'nope' });
    expect(result.response.status).toBe(400);
    expect(result.rpcCalls).toEqual([]);
  });
});

describe('Command Center activity', () => {
  it('uses the selected day, the timezone and user-only messages', async () => {
    const result = await run('analytics-activity', { mode: 'day', dateRange: range, timeZone: 'America/Sao_Paulo' });
    expect(result.response.status).toBe(200);
    const data = json(result);
    expect(data).toHaveLength(24);
    expect(data.reduce((sum: number, row: any) => sum + row.mensagens, 0)).toBe(5);
    expect(data[0]).toEqual({ label: '00h', mensagens: 5, usuarios: 2 });
  });
  it('limits daily buckets to the selected period, not today or all history', async () => {
    expect(json(await run('analytics-activity', { mode: 'week', dateRange: range, timeZone: 'America/Sao_Paulo' })))
      .toEqual([{ label: '15/06', mensagens: 5, usuarios: 2 }]);
  });
  it('buckets by the requested time zone at the day boundary (23:59 / 00:00 BRT)', async () => {
    const boundary = { chat_messages: [
      { user_id: A, sender: 'user', created_at: '2026-06-16T02:59:59.999Z' }, // 15/06 23:59:59.999 BRT
      { user_id: B, sender: 'user', created_at: '2026-06-16T03:00:00.000Z' }, // 16/06 00:00 BRT
    ] };
    const week = { mode: 'week', dateRange: { from: '2026-06-15T03:00:00.000Z', to: '2026-06-17T03:00:00.000Z' } };
    expect(json(await run('analytics-activity', { ...week, timeZone: 'America/Sao_Paulo' }, boundary)))
      .toEqual([{ label: '15/06', mensagens: 1, usuarios: 1 }, { label: '16/06', mensagens: 1, usuarios: 1 }]);
    expect(json(await run('analytics-activity', { ...week, timeZone: 'UTC' }, boundary)))
      .toEqual([{ label: '15/06', mensagens: 0, usuarios: 0 }, { label: '16/06', mensagens: 2, usuarios: 2 }, { label: '17/06', mensagens: 0, usuarios: 0 }]);
  });
  it('adds the year to labels when the period crosses years', async () => {
    const data = json(await run('analytics-activity', { mode: 'week', timeZone: 'America/Sao_Paulo',
      dateRange: { from: '2025-12-31T03:00:00.000Z', to: '2026-01-02T03:00:00.000Z' } }));
    expect(data.map((row: any) => row.label)).toEqual(['31/12/2025', '01/01/2026']);
  });
  it.each([
    [{ mode: 'month' }, 'Modo de atividade inválido'],
    [{ mode: 'day', zoomHour: 24 }, 'Modo de atividade inválido'],
    [{ mode: 'week', timeZone: 'Mars/Olympus' }, 'Fuso horário inválido'],
  ])('rejects %j with 400 before querying', async (body, error) => {
    const result = await run('analytics-activity', body);
    expect(result.response.status).toBe(400);
    expect(json(result).error).toBe(error);
    expect(result.rpcCalls).toEqual([]);
  });
});

describe('Command Center stats', () => {
  it('keeps active and recurring users in the selected window, excluding automated messages', async () => {
    const result = await run('analytics-stats', { dateRange: range });
    expect(result.response.status).toBe(200);
    expect(json(result)).toMatchObject({ totalMessages: 5, activeUsersWithMessages: 2, activeUsers: 2, powerUsers: 1 });
  });
  it('does not invent a percentage when the previous period has no denominator', async () => {
    const result = await run('analytics-stats', { dateRange: range },
      { ...tables, chat_messages: messages.filter(message => message.created_at >= range.from) });
    expect(json(result)).not.toHaveProperty('messagesChange');
  });
  it('keeps the response keys and order of the previous implementation', async () => {
    expect(Object.keys(json(await run('analytics-stats', { dateRange: range })))).toEqual([
      'totalRegistered', 'activeUsers', 'activeUsersWithMessages', 'catalogUsers', 'activeUsersChange',
      'totalMessages', 'messagesChange', 'totalFavorites', 'powerUsers', 'powerUsersList',
    ]);
  });
});

describe('analytics-stats user message volume', () => {
  const dateRange = { from: '2026-10-08T00:00:00Z', to: '2026-10-09T00:00:00Z' };
  const rows = [
    { sender: 'user', created_at: '2026-10-07T00:00:00Z' },
    { sender: 'user', created_at: '2026-10-08T00:00:00Z' },
    { sender: 'user', created_at: '2026-10-08T12:00:00Z' },
    { sender: 'cloudinha', created_at: '2026-10-08T12:01:00Z' },
    { sender: 'system', created_at: '2026-10-08T12:02:00Z' },
    { sender: null, created_at: '2026-10-08T12:03:00Z' },
    { sender: 'user', created_at: '2026-10-09T00:00:00Z' },
  ];
  const volume = async (body: unknown, data = rows) => {
    const result = json(await run('analytics-stats', body, { chat_messages: data }));
    return { totalMessages: result.totalMessages, messagesChange: result.messagesChange };
  };
  afterEach(() => { vi.useRealTimers(); });

  it('excludes assistant, system and missing roles in both periods; uses [from,to)', async () => {
    expect(await volume({ dateRange })).toEqual({ totalMessages: 2, messagesChange: 100 });
  });
  it('keeps legacy all-time total without a range, but filters user in weekly comparison too', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-10-09T12:00:00Z'));
    expect(await volume({})).toEqual({ totalMessages: 4, messagesChange: undefined });
  });
  it('uses adjacent equal-length periods rather than a hard-coded week', async () => {
    expect(await volume({ dateRange: { from: '2026-10-07T00:00:00Z', to: '2026-10-09T00:00:00Z' } }))
      .toEqual({ totalMessages: 3, messagesChange: undefined });
  });
  it('returns a real zero for an empty user-message period', async () => {
    expect(await volume({ dateRange }, [])).toEqual({ totalMessages: 0, messagesChange: undefined });
  });
  it('filters the denominator too, allowing a real decrease instead of counting system traffic', async () => {
    const mixed = [...rows,
      ...Array.from({ length: 3 }, () => ({ sender: 'user', created_at: '2026-10-07T12:00:00Z' })),
      ...Array.from({ length: 10 }, () => ({ sender: 'system', created_at: '2026-10-07T12:00:00Z' })),
    ];
    expect(await volume({ dateRange }, mixed)).toEqual({ totalMessages: 2, messagesChange: -50 });
  });
  it.each([
    { from: 'invalid', to: dateRange.to },
    { from: dateRange.from },
    { from: dateRange.to, to: dateRange.from },
    { from: dateRange.from, to: dateRange.from },
  ])('rejects invalid or incomplete periods: %j', async (period) => {
    const result = await run('analytics-stats', { dateRange: period });
    expect(result.response.status).toBe(400);
    expect(json(result).error).toBe('Período inválido');
    expect(result.rpcCalls).toEqual([]);
  });
});

describe('Command Center boundaries', () => {
  const entries = ['analytics-stats', 'analytics-rankings', 'analytics-activity'];
  it.each(entries)('denies non-admin callers before any service-role data access: %s', async entry => {
    const result = await run(entry, { dateRange: range }, tables, { admin: false });
    expect(result.response.status).toBe(403);
    expect(result.createClient).toHaveBeenCalledTimes(1);
    expect(result.rpcCalls).toHaveLength(0);
  });
  it.each(entries)('rejects malformed JSON: %s', async entry => {
    expect((await run(entry, '{')).response.status).toBe(400);
  });
  it.each(entries)('allows preflight without touching any client or data: %s', async entry => {
    const app = edgeHarness('supabase/functions/' + entry + '/index.ts', {});
    expect((await app.handler(new Request('https://example.test', { method: 'OPTIONS' }))).status).toBe(200);
    expect(app.createClient).not.toHaveBeenCalled();
  });
  it.each(entries)('rejects an unauthenticated request before creating any client: %s', async entry => {
    const app = edgeHarness('supabase/functions/' + entry + '/index.ts', {});
    expect((await app.handler(new Request('https://example.test'))).status).toBe(401);
    expect(app.createClient).not.toHaveBeenCalled();
  });
  it('counts real previous recurring users, not an estimated percentage of the current count', async () => {
    const previous = [
      { user_id: B, sender: 'user', created_at: '2026-06-14T03:00:00Z' },
      { user_id: B, sender: 'user', created_at: '2026-06-14T04:00:00Z' },
    ];
    expect(json(await run('analytics-stats', { dateRange: range }, { ...tables, chat_messages: [...messages, ...previous] })))
      .toMatchObject({ powerUsers: 1, powerUsersChange: 0 });
  });
  it('keeps 15-minute activity zoom inside the selected hour and window', async () => {
    const result = await run('analytics-activity', { mode: 'day', zoomHour: 0, dateRange: range, timeZone: 'America/Sao_Paulo' });
    expect(json(result).map((row: any) => row.mensagens)).toEqual([4, 0, 1, 0]);
    expect(json(result).map((row: any) => row.label)).toEqual(['00:00', '00:15', '00:30', '00:45']);
  });
});
