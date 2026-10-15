/**
 * NUB-RD-86 (A4) — Vercel Function: proxy da API do Snaps para o admin.
 * A lógica (autorização, lista de caminhos, repasse) está em
 * src/lib/server/snapsProxy.ts, com testes. Aqui só se liga o handler.
 *
 * Variáveis de RUNTIME (passadas no deploy, nunca no bundle):
 *   SNAPS_API_KEY, SNAPS_API_URL, VITE_SNAPS_PROJECT_ID,
 *   VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY
 */
import { envDoProcesso, handleSnapsProxy } from '../../src/lib/server/snapsProxy';

function proxy(request: Request): Promise<Response> {
  return handleSnapsProxy(request, envDoProcesso(process.env));
}

export const GET = proxy;
export const POST = proxy;
export const PATCH = proxy;
export const DELETE = proxy;
