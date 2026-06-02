/**
 * snapsClient.ts
 * Cliente HTTP para a API pública do Snaps (/public/projects/).
 * Injeta o header x-api-key em todas as requisições.
 */

const BASE_URL = import.meta.env.VITE_SNAPS_BASE_URL ?? 'http://localhost:3001';
const API_KEY = import.meta.env.VITE_SNAPS_API_KEY ?? '';

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE_URL}/public/projects${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': API_KEY,
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
