/**
 * snapsClient.ts
 * Cliente HTTP para a API pública do Snaps (/public/projects/).
 * Vai pelo proxy do admin (/api/snaps); o x-api-key leva o token da sessão
 * (NUB-RD-86 A4) — a chave do Snaps não está mais no bundle.
 */
import { SNAPS_PROXY_URL, snapsSessionToken } from '@/lib/snapsProxyClient';

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${SNAPS_PROXY_URL}/public/projects${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': await snapsSessionToken(),
      ...init?.headers,
    },
  });

  if (!res.ok) {
    throw new Error(`Snaps API error ${res.status}: ${await res.text()}`);
  }

  return res.json() as Promise<T>;
}

// ---------------------------------------------------------------------------
// Tipos base
// ---------------------------------------------------------------------------

export interface SnapsSprint {
  id: string;
  name: string;
  status: string;
  objective?: string;
  created_at: string;
}

export interface SnapsCard {
  id: string;
  title: string;
  status: string;
  card_type: string;
  description?: string;
  sprint_id: string;
}

export interface CreateCardPayload {
  title: string;
  description?: string;
  card_type: 'bug' | 'feature' | 'support';
  sprint_id?: string;
}

// ---------------------------------------------------------------------------
// Funções de acesso
// ---------------------------------------------------------------------------

/** Retorna todas as sprints do projeto (roadmap). */
export function getRoadmap(): Promise<SnapsSprint[]> {
  return request<SnapsSprint[]>('/sprints');
}

/** Retorna os cards de uma sprint específica. */
export function getSprintCards(sprintId: string): Promise<SnapsCard[]> {
  return request<SnapsCard[]>(`/sprints/${sprintId}/cards`);
}

/** Retorna todos os cards de suporte (bugs / support tickets). */
export function getSupportCards(): Promise<SnapsCard[]> {
  return request<SnapsCard[]>('/cards?card_type=bug,support');
}

/** Cria um novo card de suporte (bug report ou feature request). */
export function createSupportCard(payload: CreateCardPayload): Promise<SnapsCard> {
  return request<SnapsCard>('/cards', {
    method: 'POST',
    body: JSON.stringify(payload),
  });
}
