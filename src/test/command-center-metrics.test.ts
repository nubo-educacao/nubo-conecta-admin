import { edgeHarness, testDatabase, edgeRequest } from './edgeHarness';

const range = { from: '2026-06-15T03:00:00.000Z', to: '2026-06-16T03:00:00.000Z' };
const messages = [
  ...[0, 5, 40].map(minute => ({ user_id: 'a', sender: 'user', created_at: new Date(Date.parse(range.from) + minute * 60000).toISOString() })),
  ...[1, 2].map(minute => ({ user_id: 'b', sender: 'user', created_at: new Date(Date.parse(range.from) + minute * 60000).toISOString() })),
  { user_id: 'c', sender: 'system', created_at: range.from },
  { user_id: 'a', sender: 'cloudinha', created_at: range.from },
  { user_id: 'a', sender: 'user', created_at: range.to },
  { user_id: 'b', sender: 'user', created_at: '2026-06-14T12:00:00.000Z' },
];
const tables = { chat_messages: messages,
  user_profiles: ['a', 'b', 'c'].map(id => ({ id, full_name: id })),
  user_favorites: Array.from({ length: 20 }, () => ({ user_id: 'b', created_at: range.from })),
  user_preferences: [], agent_errors: [],
};

describe('Command Center message rankings', () => {
  it('ranks by user-message count, not favorites; excludes zero senders and other periods', async () => {
    const db = testDatabase(tables);
    const app = edgeHarness('supabase/functions/analytics-rankings/index.ts', db.client);
    const response = await app.handler(edgeRequest({ type: 'users', dateRange: range }));
    expect(response.status).toBe(200);
    expect((await response.json()).map((user: any) => [user.id, user.messages, user.sessions])).toEqual([['a', 3, 2], ['b', 2, 1]]);
    expect(db.calls.filter(call => call.table === 'chat_messages').every(call => call.filters.some(filter => filter[0] === 'eq' && filter[1] === 'sender' && filter[2] === 'user'))).toBe(true);
  });
  it('returns an empty ranking instead of listing every registered profile', async () => {
    const { client } = testDatabase({ ...tables, chat_messages: [] });
    expect(await (await edgeHarness('supabase/functions/analytics-rankings/index.ts', client).handler(edgeRequest({ type: 'users', dateRange: range }))).json()).toEqual([]);
  });
  it('propagates source failure instead of returning an apparently successful empty ranking', async () => {
    const { client } = testDatabase(tables, { chat_messages: 'source unavailable' });
    expect((await edgeHarness('supabase/functions/analytics-rankings/index.ts', client).handler(edgeRequest({ type: 'users', dateRange: range }))).status).toBe(500);
  });
});

describe('Command Center activity', () => {
  it('uses the selected day, the timezone and user-only messages', async () => {
    const { client } = testDatabase(tables);
    const response = await edgeHarness('supabase/functions/analytics-activity/index.ts', client).handler(edgeRequest({ mode: 'day', dateRange: range, timeZone: 'America/Sao_Paulo' }));
    expect(response.status).toBe(200);
    const data = await response.json();
    expect(data.reduce((sum: number, row: any) => sum + row.mensagens, 0)).toBe(5);
    expect(data[0]).toMatchObject({ label: '00h', mensagens: 5, usuarios: 2 });
  });
  it('limits daily buckets to the selected period, not today or all history', async () => {
    const { client } = testDatabase(tables);
    const response = await edgeHarness('supabase/functions/analytics-activity/index.ts', client).handler(edgeRequest({ mode: 'week', dateRange: range, timeZone: 'America/Sao_Paulo' }));
    expect(await response.json()).toEqual([{ label: '15/06', mensagens: 5, usuarios: 2 }]);
  });
});

describe('Command Center stats', () => {
  it('keeps active and recurring users in the selected window, excluding automated messages', async () => {
    const { client } = testDatabase(tables);
    const response = await edgeHarness('supabase/functions/analytics-stats/index.ts', client).handler(edgeRequest({ dateRange: range }));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ totalMessages: 5, activeUsersWithMessages: 2, activeUsers: 2, powerUsers: 1 });
  });
  it('does not invent a percentage when the previous period has no denominator', async () => {
    const { client } = testDatabase({ ...tables, chat_messages: messages.filter(message => message.created_at >= range.from) });
    const response = await edgeHarness('supabase/functions/analytics-stats/index.ts', client).handler(edgeRequest({ dateRange: range }));
    expect(await response.json()).not.toHaveProperty('messagesChange');
  });
});

describe('Command Center boundaries', () => {
  const entries = ['analytics-stats', 'analytics-rankings', 'analytics-activity'];
  it.each(entries)('denies non-admin callers before any service-role data access: %s', async entry => {
    const db = testDatabase(tables);
    db.client.rpc = async () => ({ data: false, error: null });
    const app = edgeHarness('supabase/functions/' + entry + '/index.ts', db.client);
    expect((await app.handler(edgeRequest({ dateRange: range }))).status).toBe(403);
    expect(app.createClient).toHaveBeenCalledTimes(1);
    expect(db.calls).toHaveLength(0);
  });
  it.each(entries)('rejects malformed JSON: %s', async entry => {
    const db = testDatabase(tables);
    const response = await edgeHarness('supabase/functions/' + entry + '/index.ts', db.client).handler(
      new Request('https://example.test', { method: 'POST', headers: { Authorization: 'Bearer test-only' }, body: '{' }));
    expect(response.status).toBe(400);
  });
  it('paginates beyond the PostgREST limit without losing messages', async () => {
    const db = testDatabase({ ...tables, chat_messages: Array.from({ length: 1005 }, (_, id) =>
      ({ id, user_id: 'a', sender: 'user', created_at: range.from })) });
    const response = await edgeHarness('supabase/functions/analytics-rankings/index.ts', db.client).handler(edgeRequest({ type: 'users', dateRange: range }));
    expect((await response.json())[0].messages).toBe(1005);
    expect(db.calls.filter(call => call.table === 'chat_messages')).toHaveLength(2);
  });
  it('counts real previous recurring users, not an estimated percentage of the current count', async () => {
    const previous = [
      { user_id: 'b', sender: 'user', created_at: '2026-06-14T03:00:00Z' },
      { user_id: 'b', sender: 'user', created_at: '2026-06-14T04:00:00Z' },
    ];
    const db = testDatabase({ ...tables, chat_messages: [...messages, ...previous] });
    const response = await edgeHarness('supabase/functions/analytics-stats/index.ts', db.client).handler(edgeRequest({ dateRange: range }));
    expect(await response.json()).toMatchObject({ powerUsers: 1, powerUsersChange: 0 });
  });
  it('keeps 15-minute activity zoom inside the selected hour and window', async () => {
    const db = testDatabase(tables);
    const response = await edgeHarness('supabase/functions/analytics-activity/index.ts', db.client).handler(
      edgeRequest({ mode: 'day', zoomHour: 0, dateRange: range, timeZone: 'America/Sao_Paulo' }));
    expect((await response.json()).map((row: any) => row.mensagens)).toEqual([4, 0, 1, 0]);
  });
});
