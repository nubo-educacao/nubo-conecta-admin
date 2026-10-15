/**
 * NUB-RD-86 (A4) — o navegador fala com o Snaps só pelo proxy do admin e se
 * identifica com o token da sessão; nenhuma chave do Snaps no código do cliente.
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('@/integrations/supabase/client', () => ({
  supabase: { auth: { getSession: vi.fn(async () => ({ data: { session: { access_token: 'token-da-sessao' } } })) } },
}));

import { deleteCard, fetchRoadmapSprints, uploadSupportAttachment } from '@/services/snapsApiService';

const mockFetch = vi.fn(async () => new Response(JSON.stringify({ sprints: [] }), { status: 200 }));

beforeEach(() => vi.stubGlobal('fetch', mockFetch));
afterEach(() => { mockFetch.mockClear(); vi.unstubAllGlobals(); });

describe('snapsApiService via proxy', () => {
  it('chama /api/snaps com o token da sessão em X-API-Key', async () => {
    await fetchRoadmapSprints();
    const [url, init] = mockFetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(url.startsWith('/api/snaps/public/projects/')).toBe(true);
    expect(url.endsWith('/roadmap')).toBe(true);
    expect((init.headers as Record<string, string>)['X-API-Key']).toBe('token-da-sessao');
  });

  it('o delete usa a rota de cards do proxy', async () => {
    mockFetch.mockResolvedValueOnce(new Response('{"ok":true}', { status: 200 }));
    await deleteCard('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
    expect((mockFetch.mock.calls[0] as unknown as [string])[0]).toBe('/api/snaps/cards/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
  });

  it('o upload manda só o token da sessão (sem Authorization com chave)', async () => {
    mockFetch.mockResolvedValueOnce(new Response('{"url":"u"}', { status: 200 }));
    await uploadSupportAttachment(new File(['x'], 'a.txt'));
    const [, init] = mockFetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(init.headers).toEqual({ 'X-API-Key': 'token-da-sessao' });
  });
});

describe('nenhuma chave do Snaps no código do cliente', () => {
  function arquivos(dir: string): string[] {
    return readdirSync(dir).flatMap((n) => {
      const p = join(dir, n);
      return statSync(p).isDirectory() ? arquivos(p) : [p];
    });
  }

  it('nenhum arquivo de src/ (fora dos testes) lê VITE_SNAPS_API_KEY ou VITE_SNAPS_API_URL', () => {
    const achados = arquivos('src')
      .filter((p) => /\.(ts|tsx)$/.test(p) && !/\.(test|spec)\.tsx?$/.test(p))
      .filter((p) => /VITE_SNAPS_API_(KEY|URL)/.test(readFileSync(p, 'utf8')));
    expect(achados).toEqual([]);
  });
});
