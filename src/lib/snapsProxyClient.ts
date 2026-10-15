/**
 * NUB-RD-86 (A4) — como o navegador fala com a API do Snaps.
 *
 * Sempre pelo proxy do próprio admin (`/api/snaps`, Vercel Function), nunca
 * direto: a chave do Snaps fica só no servidor. O header `X-API-Key` leva o
 * access_token da sessão Supabase do usuário, que o proxy valida (sessão +
 * user_permissions) antes de trocá-lo pela chave do servidor.
 */
import { supabase } from '@/integrations/supabase/client';

export const SNAPS_PROXY_URL = '/api/snaps';

/** Projeto do Snaps: identificador público, segue no bundle. */
export const SNAPS_PROJECT_ID = (import.meta.env.VITE_SNAPS_PROJECT_ID as string | undefined) ?? '';

export async function snapsSessionToken(): Promise<string> {
  const { data } = await supabase.auth.getSession();
  return data.session?.access_token ?? '';
}
