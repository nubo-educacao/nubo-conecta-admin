import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import ts from 'typescript';

// Evaluate the actual Deno source with only its external client/runtime substituted.
export function edgeHarness(entry: string, client: any, overrides: Record<string, any> = {}) {
  let handler: (req: Request) => Promise<Response>;
  const createClient = vi.fn(() => client);
  const cache = new Map<string, any>();
  function load(path: string): any {
    const absolute = resolve(path);
    if (cache.has(absolute)) return cache.get(absolute);
    const exports = {};
    cache.set(absolute, exports);
    const compiled = ts.transpileModule(readFileSync(absolute, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    const requireModule = (name: string) => name.startsWith('https://') ? { createClient }
      : overrides[name] ?? load(resolve(dirname(absolute), name));
    new Function('exports', 'require', 'Deno', compiled)(exports, requireModule, {
      serve: (fn: typeof handler) => { handler = fn; }, env: { get: () => 'test-only' },
    });
    return exports;
  }
  const exports = load(entry);
  return { exports, createClient, handler: (request: Request) => handler(request) };
}

export function testDatabase(tables: Record<string, any[]>, failures: Record<string, string> = {}) {
  const calls: { table: string; filters: any[] }[] = [];
  const client: any = {
    auth: { getUser: async () => ({ data: { user: { id: 'admin' } }, error: null }),
      admin: { listUsers: async () => ({ data: { total: 50, users: [] }, error: null }) } },
    rpc: async () => ({ data: true, error: null }),
    from: (table: string) => {
      const call = { table, filters: [] as any[] }; calls.push(call);
      let rows = [...(tables[table] ?? [])], options: any = {}, start = 0, end = Infinity;
      const query: any = {
        select: (_columns: string, config = {}) => { options = config; return query; },
        order: () => query,
        range: (from: number, to: number) => { start = from; end = to; return query; },
        eq: (column: string, value: any) => { call.filters.push(['eq', column, value]); rows = rows.filter(row => row[column] === value); return query; },
        gte: (column: string, value: string) => { call.filters.push(['gte', column, value]); rows = rows.filter(row => Date.parse(row[column]) >= Date.parse(value)); return query; },
        lt: (column: string, value: string) => { call.filters.push(['lt', column, value]); rows = rows.filter(row => Date.parse(row[column]) < Date.parse(value)); return query; },
        not: (column: string) => { rows = rows.filter(row => row[column] != null); return query; },
        then: (resolveValue: any) => Promise.resolve({
          data: options.head ? null : rows.slice(start, end + 1), count: rows.length,
          error: failures[table] ? { message: failures[table] } : null,
        }).then(resolveValue),
      };
      return query;
    },
  };
  return { client, calls };
}

export const edgeRequest = (body: any) => new Request('https://example.test', {
  method: 'POST', headers: { Authorization: 'Bearer test-only' }, body: JSON.stringify(body),
});
