// Recorte por campanha/divulgador nas Edge Functions do Command Center.
//
// Mesmo contrato das RPCs (TP-7 / NHB-123b, artefato 46d78fd5, confirmado pelo
// PO em 15/10/2026): a pessoa pertence à campanha/divulgador do link do seu
// PRIMEIRO toque — user_attribution.first_touch_link_id → channel_links.
// Último toque não entra; links arquivados continuam valendo. "Sem atribuição"
// = sem linha em user_attribution ou first_touch_link_id nulo, e é exclusivo
// com campanha/divulgador. user_attribution tem PK em user_id: nunca multiplica.
//
// O recorte em si é feito em SQL pelas RPCs cc_*_aggregate (NUB-RD-93).
// Sem import de propósito: roda em Deno e nos testes (vitest/edgeHarness).

export interface AttributionFilterBody {
  campaignId?: string
  channelId?: string
  unattributed?: true
}

export class AttributionFilterError extends Error {
  constructor(message = 'Filtro de atribuição inválido') {
    super(message)
    this.name = 'AttributionFilterError'
  }
}

export const isAttributionFilterError = (error: unknown) =>
  error instanceof Error && error.name === 'AttributionFilterError'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function readUuid(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'string' || !UUID.test(value)) throw new AttributionFilterError()
  return value
}

/** Lê {campaignId, channelId, unattributed} do corpo. Nada ativo → null. */
export function parseAttributionFilter(body: unknown): AttributionFilterBody | null {
  if (!body || typeof body !== 'object') return null
  const raw = body as Record<string, unknown>
  const campaignId = readUuid(raw.campaignId)
  const channelId = readUuid(raw.channelId)
  if (raw.unattributed !== undefined && raw.unattributed !== null && typeof raw.unattributed !== 'boolean') {
    throw new AttributionFilterError()
  }
  if (raw.unattributed === true) {
    if (campaignId || channelId) {
      throw new AttributionFilterError('Filtro de atribuição incompatível: "sem atribuição" não combina com campanha/divulgador')
    }
    return { unattributed: true }
  }
  if (!campaignId && !channelId) return null
  return { ...(campaignId && { campaignId }), ...(channelId && { channelId }) }
}

/** Parâmetros p_filter_* das RPCs do Command Center (todos nulos = sem recorte). */
export function attributionRpcArgs(filter: AttributionFilterBody | null) {
  return {
    p_filter_campaign_id: filter?.campaignId ?? null,
    p_filter_channel_id: filter?.channelId ?? null,
    p_filter_unattributed: filter?.unattributed ?? null,
  }
}
