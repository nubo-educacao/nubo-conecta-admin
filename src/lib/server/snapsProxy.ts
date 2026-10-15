/**
 * NUB-RD-86 (A4) — proxy server-side para a API do Snaps.
 *
 * Roda numa Vercel Function (`api/snaps/[...path].ts`). O navegador nunca vê a
 * chave do Snaps: manda o access_token da sessão Supabase em `X-API-Key`, e o
 * proxy
 *   1. valida a sessão no Supabase;
 *   2. exige ≥1 linha em `user_permissions` — a mesma regra do AuthContext. Só
 *      staff: alunos logam no mesmo Supabase e parceiro não vê estas telas;
 *   3. só repassa os caminhos e métodos que o admin realmente usa, e só para o
 *      projeto do Snaps configurado;
 *   4. troca o token pela chave do servidor (`SNAPS_API_KEY`, sem prefixo VITE_).
 *
 * Nenhuma resposta cita token, chave ou valor de configuração.
 */

export interface ProxyEnv {
  snapsApiUrl: string;
  snapsApiKey: string;
  snapsProjectId: string;
  supabaseUrl: string;
  supabasePublishableKey: string;
}

type Metodo = 'GET' | 'POST' | 'PATCH' | 'DELETE';

const UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
const PREFIXO = '/api/snaps';

/**
 * Caminhos (depois de /api/snaps) que o admin usa: snapsApiService, snapsClient
 * e os web components <snaps-*> carregados de /snaps/snaps-client.umd.js.
 * `{pid}` precisa ser o projeto configurado.
 */
const ROTAS: Array<{ metodos: Metodo[]; padrao: RegExp }> = [
  { metodos: ['GET'], padrao: new RegExp(`^/public/projects/(${UUID})/(roadmap|docs|support|cards)$`) },
  { metodos: ['GET'], padrao: new RegExp(`^/public/projects/(${UUID})/docs/[A-Za-z0-9_-]+$`) },
  { metodos: ['GET', 'DELETE'], padrao: new RegExp(`^/public/projects/(${UUID})/support/cards/${UUID}$`) },
  { metodos: ['POST'], padrao: new RegExp(`^/public/projects/(${UUID})/(cards|support/upload)$`) },
  { metodos: ['PATCH'], padrao: new RegExp(`^/public/projects/(${UUID})/support/cards/${UUID}/status$`) },
  // `deleteCard` do snapsApiService usa a rota de cards fora de /public.
  { metodos: ['DELETE'], padrao: new RegExp(`^/cards/${UUID}$`) },
];

function json(status: number, erro: string): Response {
  return new Response(JSON.stringify({ error: erro }), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

/** Lê a configuração do servidor. Qualquer variável ausente → null (503). */
export function envDoProcesso(e: Record<string, string | undefined>): ProxyEnv | null {
  const cfg = {
    snapsApiUrl: (e.SNAPS_API_URL ?? '').replace(/\/+$/, ''),
    snapsApiKey: e.SNAPS_API_KEY ?? '',
    snapsProjectId: e.VITE_SNAPS_PROJECT_ID ?? '',
    supabaseUrl: (e.VITE_SUPABASE_URL ?? '').replace(/\/+$/, ''),
    supabasePublishableKey: e.VITE_SUPABASE_PUBLISHABLE_KEY ?? '',
  };
  return Object.values(cfg).every((v) => v !== '') ? cfg : null;
}

function rotaPermitida(metodo: string, caminho: string, projeto: string): boolean {
  return ROTAS.some(({ metodos, padrao }) => {
    if (!metodos.includes(metodo as Metodo)) return false;
    const m = padrao.exec(caminho);
    if (!m) return false;
    // Rotas de /public/projects/{pid}/...: o pid tem de ser o configurado.
    return caminho.startsWith('/public/') ? m[1]?.toLowerCase() === projeto.toLowerCase() : true;
  });
}

async function ehStaff(token: string, env: ProxyEnv, f: typeof fetch): Promise<'ok' | 401 | 403> {
  const headers = { apikey: env.supabasePublishableKey, Authorization: `Bearer ${token}` };
  const u = await f(`${env.supabaseUrl}/auth/v1/user`, { headers });
  if (!u.ok) return 401;
  const usuario = (await u.json()) as { id?: string };
  if (!usuario?.id) return 401;
  const p = await f(
    `${env.supabaseUrl}/rest/v1/user_permissions?select=permission&user_id=eq.${encodeURIComponent(usuario.id)}&limit=1`,
    { headers },
  );
  if (!p.ok) return 403;
  const linhas = (await p.json()) as unknown[];
  return Array.isArray(linhas) && linhas.length > 0 ? 'ok' : 403;
}

/** Parâmetro que o rewrite do vercel.json usa para carregar o caminho original. */
export const PARAM_DO_REWRITE = '__snaps_path';

/**
 * O vercel.json reescreve `/api/snaps/:path*` → `/api/snaps?__snaps_path=:path*`
 * (uma função só, sem depender de rota catch-all fora do Next). Aqui a URL
 * original é reconstruída; o resto da requisição segue igual. Um `..` no
 * caminho é normalizado pela URL e cai fora do prefixo, logo em 404.
 */
export function requestDoRewrite(req: Request): Request {
  const url = new URL(req.url);
  const caminho = url.searchParams.get(PARAM_DO_REWRITE);
  if (caminho === null) return req;
  url.searchParams.delete(PARAM_DO_REWRITE);
  const original = new URL(`${PREFIXO}/${caminho.replace(/^\/+/, '')}`, url.origin);
  original.search = url.search;
  // Copia só método, headers e corpo (stream): `new Request(url, req)` também
  // copiaria o `signal`, que nem todo runtime aceita vindo de outro Request.
  const temCorpo = req.method !== 'GET' && req.method !== 'HEAD';
  return new Request(original, {
    method: req.method,
    headers: req.headers,
    body: temCorpo ? req.body : undefined,
    duplex: 'half',
  } as RequestInit & { duplex: 'half' });
}

export async function handleSnapsProxy(
  req: Request,
  env: ProxyEnv | null,
  f: typeof fetch = fetch,
): Promise<Response> {
  if (!env) return json(503, 'proxy_nao_configurado');

  const url = new URL(req.url);
  if (!url.pathname.startsWith(PREFIXO)) return json(404, 'rota_nao_permitida');
  const caminho = url.pathname.slice(PREFIXO.length);
  const metodo = req.method.toUpperCase();
  if (!rotaPermitida(metodo, caminho, env.snapsProjectId)) return json(404, 'rota_nao_permitida');

  const token = req.headers.get('x-api-key');
  if (!token) return json(401, 'sessao_ausente');
  const acesso = await ehStaff(token, env, f);
  if (acesso === 401) return json(401, 'sessao_invalida');
  if (acesso === 403) return json(403, 'sem_permissao');

  const headers = new Headers({ 'X-API-Key': env.snapsApiKey });
  const tipo = req.headers.get('content-type');
  if (tipo) headers.set('Content-Type', tipo);
  const aceita = req.headers.get('accept');
  if (aceita) headers.set('Accept', aceita);

  const upstream = await f(`${env.snapsApiUrl}${caminho}${url.search}`, {
    method: metodo,
    headers,
    body: metodo === 'GET' ? undefined : await req.arrayBuffer(),
  });

  const saida = new Headers({ 'Cache-Control': 'no-store' });
  const tipoResposta = upstream.headers.get('content-type');
  if (tipoResposta) saida.set('Content-Type', tipoResposta);
  return new Response(upstream.body, { status: upstream.status, headers: saida });
}
