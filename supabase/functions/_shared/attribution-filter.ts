// Recorte por campanha/divulgador nas Edge Functions do Command Center.
//
// Mesmo contrato das RPCs (TP-7 / NHB-123b, artefato 46d78fd5, confirmado pelo
// PO em 15/10/2026): a pessoa pertence à campanha/divulgador do link do seu
// PRIMEIRO toque — user_attribution.first_touch_link_id → channel_links.
// Último toque não entra; links arquivados continuam valendo. "Sem atribuição"
// = sem linha em user_attribution ou first_touch_link_id nulo, e é exclusivo
// com campanha/divulgador. user_attribution tem PK em user_id: nunca multiplica.
//
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

// Paginação estável por coluna única; uma página com erro nunca vira recorte parcial.
// deno-lint-ignore no-explicit-any
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function fetchAll<T>(db: any, table: string, fields: string, orderBy: string, filter?: (query: any) => any): Promise<T[]> {
  const rows: T[] = []
  for (let offset = 0; ; offset += 1000) {
    let query = db.from(table).select(fields).order(orderBy, { ascending: true }).range(offset, offset + 999)
    if (filter) query = filter(query)
    const { data, error } = await query
    if (error) throw new Error(error.message ?? 'Consulta indisponível')
    if (!Array.isArray(data)) throw new Error('Resposta de consulta inválida')
    rows.push(...data)
    if (data.length < 1000) return rows
  }
}

/**
 * Ids de usuário do recorte (service client), ou null quando não há filtro —
 * nesse caso nenhuma consulta é feita e o chamador mantém o comportamento atual.
 */
// deno-lint-ignore no-explicit-any
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function resolveAttributedUserIds(db: any, filter: AttributionFilterBody | null): Promise<Set<string> | null> {
  if (!filter) return null
  const firstTouches = () => fetchAll<{ user_id: string; first_touch_link_id: string | null }>(
    db, 'user_attribution', 'user_id, first_touch_link_id', 'user_id',
    query => query.not('first_touch_link_id', 'is', null))

  if (filter.unattributed) {
    const [attributed, profiles] = await Promise.all([
      firstTouches(),
      fetchAll<{ id: string }>(db, 'user_profiles', 'id', 'id'),
    ])
    const withFirstTouch = new Set(attributed.filter(row => row.first_touch_link_id).map(row => row.user_id))
    return new Set(profiles.map(profile => profile.id).filter(id => !withFirstTouch.has(id)))
  }

  const links = await fetchAll<{ id: string }>(db, 'channel_links', 'id', 'id', query => {
    if (filter.campaignId) query = query.eq('campaign_id', filter.campaignId)
    if (filter.channelId) query = query.eq('channel_id', filter.channelId)
    return query
  })
  if (links.length === 0) return new Set()
  const linkIds = new Set(links.map(link => link.id))
  const touches = await firstTouches()
  return new Set(touches.filter(row => row.first_touch_link_id && linkIds.has(row.first_touch_link_id)).map(row => row.user_id))
}

/** Sem recorte devolve as mesmas linhas; com recorte, só as do conjunto (nulos saem). */
export function keepAllowed<T>(rows: T[], allowed: Set<string> | null, key: keyof T): T[] {
  if (!allowed) return rows
  return rows.filter(row => {
    const value = row[key]
    return typeof value === 'string' && allowed.has(value)
  })
}
