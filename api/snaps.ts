/**
 * NUB-RD-86 (A4) — Vercel Function: proxy da API do Snaps para o admin.
 *
 * O vercel.json reescreve `/api/snaps/:path*` para esta função (uma só, sem
 * depender de rota catch-all fora do Next). A lógica — autorização, lista de
 * caminhos, repasse — está em src/lib/server/snapsProxy.ts, com testes.
 *
 * Variáveis de RUNTIME (passadas no `vercel deploy --env`, nunca no bundle):
 *   SNAPS_API_KEY, SNAPS_API_URL, VITE_SNAPS_PROJECT_ID,
 *   VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY
 */
// Projeto ESM ("type": "module"): o import relativo precisa da extensão .js.
import { envDoProcesso, handleSnapsProxy, requestDoRewrite } from '../src/lib/server/snapsProxy.js';

function proxy(request: Request): Promise<Response> {
  return handleSnapsProxy(requestDoRewrite(request), envDoProcesso(process.env));
}

export const GET = proxy;
export const POST = proxy;
export const PATCH = proxy;
export const DELETE = proxy;
