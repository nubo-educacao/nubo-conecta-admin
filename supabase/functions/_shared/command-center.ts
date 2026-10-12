export interface AnalyticsRange { from: string; to: string }
export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
export const jsonResponse = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

export function periods(range?: AnalyticsRange, now = new Date()) {
  if (range !== undefined && (!range || typeof range.from !== 'string' || typeof range.to !== 'string')) throw new Error('Período inválido')
  const to = range ? new Date(range.to) : now
  const from = range ? new Date(range.from) : new Date(to.getTime() - 7 * 86400000)
  if (!Number.isFinite(from.getTime()) || !Number.isFinite(to.getTime()) || to <= from) throw new Error('Período inválido')
  return { from, to, previousFrom: new Date(from.getTime() - (to.getTime() - from.getTime())) }
}
// No denominator means no comparable percentage, not a fabricated 100%.
export const change = (current: number, previous: number) =>
  previous > 0 ? Math.round((current - previous) / previous * 100) : undefined

// deno-lint-ignore no-explicit-any
export async function authorizeBackoffice(req: Request, createClient: any) {
  const authorization = req.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return jsonResponse({ error: 'Autenticação obrigatória' }, 401)
  const caller = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } })
  const { data, error } = await caller.auth.getUser()
  if (error || !data?.user) return jsonResponse({ error: 'Sessão inválida' }, 401)
  const permission = await caller.rpc('is_backoffice_admin')
  if (permission.error || permission.data !== true) return jsonResponse({ error: 'Acesso restrito ao backoffice' }, 403)
  return null
}

// Stable pagination; a failed page never produces a partial successful metric.
// deno-lint-ignore no-explicit-any
export async function fetchRows<T>(db: any, table: string, fields: string, filter?: (query: any) => any): Promise<T[]> {
  const result: T[] = []
  for (let offset = 0; ; offset += 1000) {
    let query = db.from(table).select(fields).order('id', { ascending: true }).range(offset, offset + 999)
    if (filter) query = filter(query)
    const { data, error } = await query
    if (error) throw new Error(error.message ?? 'Consulta indisponível')
    if (!Array.isArray(data)) throw new Error('Resposta de consulta inválida')
    result.push(...data)
    if (data.length < 1000) return result
  }
}

export interface UserMessage { user_id: string | null; created_at: string }
export function sessionCounts(messages: UserMessage[]) {
  const byUser = new Map<string, number[]>()
  for (const message of messages) {
    if (!message.user_id) continue
    const times = byUser.get(message.user_id) ?? []
    times.push(Date.parse(message.created_at)); byUser.set(message.user_id, times)
  }
  const counts = new Map<string, number>()
  for (const [id, times] of byUser) {
    times.sort((a, b) => a - b)
    counts.set(id, 1 + times.slice(1).filter((time, index) => time - times[index] > 30 * 60000).length)
  }
  return counts
}
