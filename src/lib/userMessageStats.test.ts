import { readFileSync } from 'node:fs';
import ts from 'typescript';

// Execute the real Edge module with an in-memory PostgREST adapter, not a substitute metric.
function loadStats() {
  const source = readFileSync('supabase/functions/analytics-stats/user-message-stats.ts', 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
  const exports: any = {};
  new Function('exports', compiled)(exports);
  return exports.fetchUserMessageStats;
}

const now = new Date('2026-10-09T12:00:00Z');
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

function database(data = rows, error: any = null) {
  const calls: any[] = [];
  return { calls, from: (table: string) => {
    let selected = [...data];
    const query: any = {
      select: (columns: string, options: any) => { calls.push({ table, columns, options }); return query; },
      eq: (column: string, value: any) => { selected = selected.filter((row: any) => row[column] === value); return query; },
      gte: (column: string, value: string) => { selected = selected.filter((row: any) => row[column] >= value); return query; },
      lt: (column: string, value: string) => { selected = selected.filter((row: any) => row[column] < value); return query; },
      then: (resolve: any) => Promise.resolve({ count: error ? null : selected.length, error }).then(resolve),
    };
    return query;
  } };
}

describe('analytics-stats user message volume', () => {
  it('excludes assistant, system and missing roles in both periods; uses [from,to)', async () => {
    const db = database();
    expect(await loadStats()(db, dateRange, now)).toEqual({ totalMessages: 2, messagesChange: 100 });
    expect(db.calls.every(call => call.table === 'chat_messages' && call.options.count === 'exact' && call.options.head)).toBe(true);
  });
  it('keeps legacy all-time total without a range, but filters user in weekly comparison too', async () => {
    expect(await loadStats()(database(), undefined, now)).toEqual({ totalMessages: 4, messagesChange: 100 });
  });
  it('uses adjacent equal-length periods rather than a hard-coded week', async () => {
    expect(await loadStats()(database(), { from: '2026-10-07T00:00:00Z', to: '2026-10-09T00:00:00Z' }, now)).toEqual({ totalMessages: 3, messagesChange: 100 });
  });
  it('returns a real zero for an empty user-message period', async () => {
    expect(await loadStats()(database([]), dateRange, now)).toEqual({ totalMessages: 0, messagesChange: 0 });
  });
  it('filters the denominator too, allowing a real decrease instead of counting system traffic', async () => {
    const mixed = [...rows,
      ...Array.from({ length: 3 }, () => ({ sender: 'user', created_at: '2026-10-07T12:00:00Z' })),
      ...Array.from({ length: 10 }, () => ({ sender: 'system', created_at: '2026-10-07T12:00:00Z' })),
    ];
    expect(await loadStats()(database(mixed), dateRange, now)).toEqual({ totalMessages: 2, messagesChange: -50 });
  });
  it('does not turn failed count queries into a successful zero', async () => {
    await expect(loadStats()(database(rows, { message: 'count failed' }), dateRange, now)).rejects.toThrow('count failed');
  });
  it.each([
    { from: 'invalid', to: dateRange.to },
    { from: dateRange.from },
    { from: dateRange.to, to: dateRange.from },
    { from: dateRange.from, to: dateRange.from },
  ])('rejects invalid or incomplete periods: %j', async (range) => {
    await expect(loadStats()(database(), range, now)).rejects.toThrow('Período inválido');
  });
});

function loadHandler(client: any) {
  let handler: any;
  const source = readFileSync('supabase/functions/analytics-stats/index.ts', 'utf8').replace(/^import .*$/gm, '');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.None } }).outputText;
  const fetchStats = vi.fn(loadStats());
  const createClient = vi.fn(() => client);
  new Function('Deno', 'createClient', 'fetchUserMessageStats', compiled)(
    { serve: (fn: any) => { handler = fn; }, env: { get: () => 'test-only' } }, createClient, fetchStats,
  );
  return { handler, createClient, fetchStats };
}

describe('analytics-stats access and real handler wiring', () => {
  it('allows preflight without touching any client or data', async () => {
    const app = loadHandler({});
    expect((await app.handler(new Request('https://example.test', { method: 'OPTIONS' }))).status).toBe(200);
    expect(app.createClient).not.toHaveBeenCalled();
  });
  it('rejects an unauthenticated request before creating the service client', async () => {
    const app = loadHandler({});
    expect((await app.handler(new Request('https://example.test'))).status).toBe(401);
    expect(app.createClient).not.toHaveBeenCalled();
  });
  it.each([false, null])('denies non-admin access: %j', async (isAdmin) => {
    const app = loadHandler({ auth: { getUser: async () => ({ data: { user: { id: 'test' } }, error: null }) },
      rpc: async () => ({ data: isAdmin, error: null }) });
    expect((await app.handler(new Request('https://example.test', { headers: { Authorization: 'Bearer test-only' } }))).status).toBe(403);
    expect(app.createClient).toHaveBeenCalledTimes(1);
    expect(app.fetchStats).not.toHaveBeenCalled();
  });
  it('uses the user-only count helper in the actual authenticated response', async () => {
    const countDb = database();
    const client = {
      auth: { getUser: async () => ({ data: { user: { id: 'test' } }, error: null }),
        admin: { listUsers: async () => ({ data: { total: 1, users: [] } }) } },
      rpc: async () => ({ data: true, error: null }),
      from: (table: string) => {
        if (table === 'chat_messages') {
          const query = countDb.from(table);
          // The preserved session query must not affect message-volume counts.
          query.range = () => query;
          return query;
        }
        const query: any = {
          select: () => query, gte: () => query, lt: () => query, eq: () => query,
          range: () => query,
          then: (resolve: any) => Promise.resolve({ data: [], count: 0, error: null }).then(resolve),
        };
        return query;
      },
    };
    const app = loadHandler(client);
    const response = await app.handler(new Request('https://example.test', {
      method: 'POST', headers: { Authorization: 'Bearer test-only' }, body: JSON.stringify({ dateRange }),
    }));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ totalMessages: 2, messagesChange: 100, totalRegistered: 1 });
    expect(app.fetchStats).toHaveBeenCalledWith(client, dateRange, expect.any(Date));
  });
});
