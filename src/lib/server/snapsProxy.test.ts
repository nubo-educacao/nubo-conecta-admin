/**
 * NUB-RD-86 (A4) — proxy server-side para a API do Snaps.
 *
 * Antes, a chave da API do Snaps (VITE_SNAPS_API_KEY) ia no bundle público do
 * admin. Agora o navegador manda o access_token da sessão Supabase no header
 * X-API-Key; o proxy valida a sessão, exige ≥1 permissão em user_permissions
 * (só staff: alunos logam no mesmo Supabase) e só então troca o token pela chave
 * do servidor, apenas para os caminhos que o admin realmente usa.
 */
import { describe, expect, it, vi } from 'vitest';
import { envDoProcesso, handleSnapsProxy, requestDoRewrite, type ProxyEnv } from './snapsProxy';

const PID = '11111111-2222-3333-4444-555555555555';
const OUTRO_PID = '99999999-2222-3333-4444-555555555555';
const CARD = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const CHAVE = 'chave-do-servidor-sentinela';
const TOKEN = 'token-da-sessao-sentinela';

const ENV: ProxyEnv = {
  snapsApiUrl: 'https://snaps.example',
  snapsApiKey: CHAVE,
  snapsProjectId: PID,
  supabaseUrl: 'https://sb.example',
  supabasePublishableKey: 'sb_publishable_x',
};

type Upstream = { url: string; init: RequestInit };

function fetchFalso(opts: { usuario?: number; permissoes?: unknown[]; snaps?: Response } = {}) {
  const chamadas: Upstream[] = [];
  const impl = vi.fn(async (url: string, init: RequestInit = {}) => {
    chamadas.push({ url, init });
    if (url.startsWith('https://sb.example/auth/v1/user')) {
      const status = opts.usuario ?? 200;
      return new Response(JSON.stringify(status === 200 ? { id: 'user-1' } : {}), { status });
    }
    if (url.startsWith('https://sb.example/rest/v1/user_permissions')) {
      return new Response(JSON.stringify(opts.permissoes ?? [{ permission: 'admin' }]), { status: 200 });
    }
    return opts.snaps ?? new Response(JSON.stringify({ ok: true }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  });
  return { impl: impl as unknown as typeof fetch, chamadas };
}

function pedido(caminho: string, init: RequestInit & { token?: string | null } = {}) {
  const headers = new Headers(init.headers);
  if (init.token !== null) headers.set('X-API-Key', init.token ?? TOKEN);
  return new Request(`https://admin.example/api/snaps${caminho}`, { ...init, headers });
}

describe('autenticação e autorização', () => {
  it('sem token devolve 401 e não chama o Snaps', async () => {
    const f = fetchFalso();
    const r = await handleSnapsProxy(pedido(`/public/projects/${PID}/roadmap`, { token: null }), ENV, f.impl);
    expect(r.status).toBe(401);
    expect(f.chamadas.some((c) => c.url.startsWith('https://snaps.example'))).toBe(false);
  });

  it('sessão inválida no Supabase devolve 401', async () => {
    const f = fetchFalso({ usuario: 401 });
    const r = await handleSnapsProxy(pedido(`/public/projects/${PID}/roadmap`), ENV, f.impl);
    expect(r.status).toBe(401);
  });

  it('usuário logado mas sem user_permissions (aluno) devolve 403', async () => {
    const f = fetchFalso({ permissoes: [] });
    const r = await handleSnapsProxy(pedido(`/public/projects/${PID}/roadmap`), ENV, f.impl);
    expect(r.status).toBe(403);
    expect(f.chamadas.some((c) => c.url.startsWith('https://snaps.example'))).toBe(false);
  });

  it('valida a sessão com o token do usuário e consulta as permissões dele', async () => {
    const f = fetchFalso();
    await handleSnapsProxy(pedido(`/public/projects/${PID}/roadmap`), ENV, f.impl);
    const auth = f.chamadas.find((c) => c.url.startsWith('https://sb.example/auth/v1/user'))!;
    const h = new Headers(auth.init.headers);
    expect(h.get('Authorization')).toBe(`Bearer ${TOKEN}`);
    expect(h.get('apikey')).toBe('sb_publishable_x');
    const perm = f.chamadas.find((c) => c.url.includes('/rest/v1/user_permissions'))!;
    expect(perm.url).toContain('user_id=eq.user-1');
  });
});

describe('lista de caminhos permitidos', () => {
  it.each([
    ['GET', `/public/projects/${PID}/roadmap`],
    ['GET', `/public/projects/${PID}/docs`],
    ['GET', `/public/projects/${PID}/docs/${CARD}`],
    ['GET', `/public/projects/${PID}/support?status=todo`],
    ['GET', `/public/projects/${PID}/support/cards/${CARD}`],
    ['GET', `/public/projects/${PID}/cards`],
    ['POST', `/public/projects/${PID}/cards`],
    ['POST', `/public/projects/${PID}/support/upload`],
    ['PATCH', `/public/projects/${PID}/support/cards/${CARD}/status`],
    ['DELETE', `/public/projects/${PID}/support/cards/${CARD}`],
    ['DELETE', `/cards/${CARD}`],
  ])('%s %s é repassado', async (metodo, caminho) => {
    const f = fetchFalso();
    const r = await handleSnapsProxy(pedido(caminho, { method: metodo }), ENV, f.impl);
    expect(r.status).toBe(200);
    const up = f.chamadas.find((c) => c.url.startsWith('https://snaps.example'))!;
    expect(up.url).toBe(`https://snaps.example${caminho}`);
    expect(up.init.method).toBe(metodo);
  });

  it.each([
    ['GET', `/public/projects/${OUTRO_PID}/roadmap`],
    ['GET', `/api/projects/${PID}/cards`],
    ['GET', `/public/projects/${PID}/../../admin`],
    ['DELETE', `/public/projects/${PID}/docs/${CARD}`],
    ['GET', `/cards/${CARD}`],
    ['DELETE', `/cards/nao-e-uuid`],
    ['POST', `/public/projects/${PID}/roadmap`],
  ])('%s %s é recusado com 404 sem chamar o Snaps', async (metodo, caminho) => {
    const f = fetchFalso();
    const r = await handleSnapsProxy(pedido(caminho, { method: metodo }), ENV, f.impl);
    expect(r.status).toBe(404);
    expect(f.chamadas.some((c) => c.url.startsWith('https://snaps.example'))).toBe(false);
  });
});

describe('repasse', () => {
  it('troca o token da sessão pela chave do servidor e não encaminha o token', async () => {
    const f = fetchFalso();
    await handleSnapsProxy(pedido(`/public/projects/${PID}/roadmap`), ENV, f.impl);
    const up = f.chamadas.find((c) => c.url.startsWith('https://snaps.example'))!;
    const h = new Headers(up.init.headers);
    expect(h.get('X-API-Key')).toBe(CHAVE);
    expect(JSON.stringify([...h.entries()])).not.toContain(TOKEN);
  });

  it('repassa o corpo e o content-type (inclusive multipart do upload)', async () => {
    const f = fetchFalso();
    const corpo = '--b\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\n\r\nx\r\n--b--';
    await handleSnapsProxy(
      pedido(`/public/projects/${PID}/support/upload`, {
        method: 'POST', body: corpo, headers: { 'Content-Type': 'multipart/form-data; boundary=b' },
      }),
      ENV, f.impl,
    );
    const up = f.chamadas.find((c) => c.url.startsWith('https://snaps.example'))!;
    expect(new Headers(up.init.headers).get('Content-Type')).toBe('multipart/form-data; boundary=b');
    expect(new TextDecoder().decode(up.init.body as ArrayBuffer)).toBe(corpo);
  });

  it('devolve status e corpo do Snaps, sem vazar a chave na resposta', async () => {
    const f = fetchFalso({
      snaps: new Response(JSON.stringify({ id: 'c1' }), { status: 201, headers: { 'Content-Type': 'application/json' } }),
    });
    const r = await handleSnapsProxy(pedido(`/public/projects/${PID}/cards`, { method: 'POST', body: '{}' }), ENV, f.impl);
    expect(r.status).toBe(201);
    const texto = await r.text();
    expect(texto).toBe('{"id":"c1"}');
    expect(JSON.stringify([...r.headers.entries()]) + texto).not.toContain(CHAVE);
  });
});

describe('configuração', () => {
  it('sem configuração no servidor devolve 503, sem citar valores', async () => {
    const f = fetchFalso();
    const r = await handleSnapsProxy(pedido(`/public/projects/${PID}/roadmap`), null, f.impl);
    expect(r.status).toBe(503);
  });

  it('envDoProcesso só monta a config com todas as variáveis, e lê a chave de SNAPS_API_KEY (não pública)', () => {
    const completo = {
      SNAPS_API_URL: 'https://snaps.example/', SNAPS_API_KEY: CHAVE, VITE_SNAPS_PROJECT_ID: PID,
      VITE_SUPABASE_URL: 'https://sb.example', VITE_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_x',
    };
    expect(envDoProcesso(completo)).toEqual({ ...ENV, snapsApiUrl: 'https://snaps.example' });
    expect(envDoProcesso({ ...completo, SNAPS_API_KEY: '' })).toBeNull();
    expect(envDoProcesso({ ...completo, SNAPS_API_KEY: undefined, VITE_SNAPS_API_KEY: CHAVE })).toBeNull();
  });
});

describe('rewrite da Vercel (/api/snaps/:path* → /api/snaps?__snaps_path=)', () => {
  it('reconstrói caminho e query originais, preservando método, headers e corpo', async () => {
    const r = requestDoRewrite(new Request(
      `https://admin.example/api/snaps?__snaps_path=public/projects/${PID}/support&status=todo&limit=10`,
      { method: 'POST', headers: { 'X-API-Key': TOKEN, 'Content-Type': 'text/plain' }, body: 'oi' },
    ));
    const url = new URL(r.url);
    expect(url.pathname).toBe(`/api/snaps/public/projects/${PID}/support`);
    expect(url.searchParams.get('__snaps_path')).toBeNull();
    expect(url.searchParams.get('status')).toBe('todo');
    expect(url.searchParams.get('limit')).toBe('10');
    expect(r.method).toBe('POST');
    expect(r.headers.get('X-API-Key')).toBe(TOKEN);
    expect(await r.text()).toBe('oi');
  });

  it('sem o parâmetro do rewrite devolve a requisição como veio', () => {
    const original = new Request(`https://admin.example/api/snaps/public/projects/${PID}/roadmap`);
    expect(requestDoRewrite(original).url).toBe(original.url);
  });

  it('um caminho do rewrite com .. não escapa da lista (continua 404)', async () => {
    const f = fetchFalso();
    const r = await handleSnapsProxy(
      requestDoRewrite(new Request(`https://admin.example/api/snaps?__snaps_path=public/projects/${PID}/../../admin`,
        { headers: { 'X-API-Key': TOKEN } })),
      ENV, f.impl,
    );
    expect(r.status).toBe(404);
  });
});
