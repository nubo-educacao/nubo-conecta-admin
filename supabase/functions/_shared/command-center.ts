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

export class AggregateQueryError extends Error {
  constructor(message: string, readonly code?: string) {
    super(message)
    this.name = 'AggregateQueryError'
  }
}

// One aggregate RPC per Edge call (NUB-RD-93): a failed query never becomes a successful zero.
// deno-lint-ignore no-explicit-any
export async function callAggregate<T>(db: any, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args)
  if (error) throw new AggregateQueryError(error.message ?? 'Consulta indisponível', error.code)
  if (data === null || typeof data !== 'object') throw new Error('Resposta de consulta inválida')
  return data as T
}
