// snapsApiService — Sprint 1.0: Integração Frontend & Unificação
// Client for the Snaps public API. Used by governance components
// (BugReportForm, FeatureRequestForm) to create cards and by RoadmapBoard
// to fetch sprints/cards.

const SNAPS_BASE_URL =
  import.meta.env.VITE_SNAPS_API_URL ?? 'https://snaps.antigravity.dev';

const SNAPS_PROJECT_ID =
  import.meta.env.VITE_SNAPS_PROJECT_ID ?? '';

const SNAPS_API_KEY =
  import.meta.env.VITE_SNAPS_API_KEY ?? '';

// Debug: log env vars on load (remove after CORS issue resolved)
console.group('[snapsApiService] ENV CHECK');
console.log('BASE_URL:', SNAPS_BASE_URL);
console.log('PROJECT_ID:', SNAPS_PROJECT_ID || '⚠️ MISSING');
console.log('API_KEY set:', SNAPS_API_KEY ? '✅' : '⚠️ MISSING');
console.groupEnd();

export type CardType = 'bug' | 'feature';

export interface BugPayload {
  title: string;
  description: string;
  environment: string;
  steps_to_reproduce: string;
  expected_behavior: string;
  actual_behavior: string;
  severity?: 'low' | 'medium' | 'high' | 'critical';
}

export interface FeaturePayload {
  title: string;
  description: string;
  pain_point: string;
  expected_impact: string;
  priority?: 'low' | 'medium' | 'high';
}

export interface CreateCardRequest {
  card_type: CardType;
  title: string;
  description: string;
  metadata: BugPayload | FeaturePayload;
}

export interface CreateCardResponse {
  id: string;
  card_type: CardType;
  title: string;
  status: string;
  created_at: string;
}

export interface SnapsCard {
  id: string;
  code?: string;
  title: string;
  status: string;
  card_type: string;
  description?: string;
  priority?: string;
  created_at: string;
}

export interface SnapsSprint {
  id: string;
  name: string;
  status: string;
  cards?: SnapsCard[];
}

function headers() {
  return {
    'Content-Type': 'application/json',
    'X-API-Key': SNAPS_API_KEY,
  };
}

export async function createCard(
  payload: CreateCardRequest,
): Promise<CreateCardResponse> {
  const url = `${SNAPS_BASE_URL}/public/projects/${SNAPS_PROJECT_ID}/cards`;
  
  // Map 'metadata' to 'card_metadata' as expected by Snaps API
  const apiPayload = {
    title: payload.title,
    description: payload.description,
    card_type: payload.card_type,
    card_metadata: payload.metadata
  };

  const response = await fetch(url, {
    method: 'POST',
    headers: headers(),
    body: JSON.stringify(apiPayload),
  });
  if (!response.ok) {
    throw new Error(`snapsApiService.createCard: HTTP ${response.status}`);
  }
  return response.json() as Promise<CreateCardResponse>;
}

export interface PaginatedCards {
  items: SnapsCard[];
  total: number;
  limit: number;
  offset: number;
  has_more: boolean;
}

export async function fetchSupportCards(
  status?: string, 
  limit: number = 20, 
  offset: number = 0,
  excludeStatus?: string
): Promise<PaginatedCards> {
  const params = new URLSearchParams();
  if (status) params.set('status', status);
  if (excludeStatus) params.set('exclude_status', excludeStatus);
  params.set('limit', limit.toString());
  params.set('offset', offset.toString());
  
  const url = `${SNAPS_BASE_URL}/public/projects/${SNAPS_PROJECT_ID}/support?${params.toString()}`;
  console.log('[snapsApiService] fetchSupportCards →', url);
  const response = await fetch(url, { headers: headers() });
  if (!response.ok) {
    throw new Error(`snapsApiService.fetchSupportCards: HTTP ${response.status}`);
  }
  return response.json() as Promise<PaginatedCards>;
}

export async function fetchSingleCard(cardId: string): Promise<SnapsCard> {
  const url = `${SNAPS_BASE_URL}/public/projects/${SNAPS_PROJECT_ID}/support/cards/${cardId}`;
  console.log('[snapsApiService] fetchSingleCard →', url);
  const response = await fetch(url, { headers: headers() });
  if (!response.ok) {
    throw new Error(`snapsApiService.fetchSingleCard: HTTP ${response.status}`);
  }
  return response.json() as Promise<SnapsCard>;
}

export async function updateCardStatus(cardId: string, status: string): Promise<SnapsCard> {
  const url = `${SNAPS_BASE_URL}/public/projects/${SNAPS_PROJECT_ID}/support/cards/${cardId}/status`;
  console.log('[snapsApiService] updateCardStatus →', url, status);
  const response = await fetch(url, {
    method: 'PATCH',
    headers: headers(),
    body: JSON.stringify({ status }),
  });
  if (!response.ok) {
    throw new Error(`snapsApiService.updateCardStatus: HTTP ${response.status}`);
  }
  return response.json() as Promise<SnapsCard>;
}

export async function deleteCard(cardId: string): Promise<{ ok: boolean }> {
  const url = `${SNAPS_BASE_URL}/cards/${cardId}`;
  console.log('[snapsApiService] deleteCard →', url);
  const response = await fetch(url, {
    method: 'DELETE',
    headers: headers(),
  });
  if (!response.ok) {
    throw new Error(`snapsApiService.deleteCard: HTTP ${response.status}`);
  }
  return response.json();
}

export async function fetchRoadmapSprints(): Promise<SnapsSprint[]> {
  const url = `${SNAPS_BASE_URL}/public/projects/${SNAPS_PROJECT_ID}/roadmap`;
  console.log('[snapsApiService] fetchRoadmapSprints →', url);
  const response = await fetch(url, { headers: headers() });
  if (!response.ok) {
    throw new Error(`snapsApiService.fetchRoadmapSprints: HTTP ${response.status}`);
  }
  const data = await response.json();
  return (data.sprints ?? data) as SnapsSprint[];
}

export async function uploadSupportAttachment(file: File): Promise<{ url: string }> {
  const url = `${SNAPS_BASE_URL}/public/projects/${SNAPS_PROJECT_ID}/support/upload`;
  console.log('[snapsApiService] uploadSupportAttachment →', url);
  
  const formData = new FormData();
  formData.append('file', file);

  const response = await fetch(url, {
    method: 'POST',
    // We cannot use standard headers() because it includes Content-Type: application/json
    // For FormData, browser sets multipart/form-data with the correct boundary automatically
    headers: {
      'Authorization': `Bearer ${SNAPS_API_KEY}`,
      'X-API-Key': SNAPS_API_KEY,
    },
    body: formData,
  });

  if (!response.ok) {
    throw new Error(`snapsApiService.uploadSupportAttachment: HTTP ${response.status}`);
  }
  return response.json();
}
