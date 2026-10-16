// Canonical replacement for the deployed legacy activity handler.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { authorizeBackoffice, corsHeaders, jsonResponse, periods, fetchRows,
  type AnalyticsRange, type UserMessage } from '../_shared/command-center.ts'
import { parseAttributionFilter, resolveAttributedUserIds, keepAllowed, isAttributionFilterError } from '../_shared/attribution-filter.ts'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders })
  try {
    const denied = await authorizeBackoffice(req, createClient)
    if (denied) return denied
    const body: { mode?: string; dateRange?: AnalyticsRange; timeZone?: string; zoomHour?: number } =
      req.method === 'POST' ? await req.json() : {}
    const mode = body.mode ?? 'week'
    if (!['week', 'day', 'total'].includes(mode) || (body.zoomHour !== undefined &&
        (!Number.isInteger(body.zoomHour) || body.zoomHour < 0 || body.zoomHour > 23))) {
      return jsonResponse({ error: 'Modo de atividade inválido' }, 400)
    }
    const timeZone = body.timeZone ?? 'America/Sao_Paulo'
    let formatter: Intl.DateTimeFormat
    try {
      formatter = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit',
        day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    } catch { return jsonResponse({ error: 'Fuso horário inválido' }, 400) }
    const local = (value: string | Date) => {
      const parts = Object.fromEntries(formatter.formatToParts(new Date(value)).map(part => [part.type, part.value]))
      return { day: parts.year + '-' + parts.month + '-' + parts.day, hour: Number(parts.hour), minute: Number(parts.minute) }
    }
    // Legacy callers without a global filter keep today's/last-seven-days/full-history views.
    const now = new Date()
    const today = local(now).day
    const tomorrow = new Date(Date.parse(today + 'T12:00:00Z') + 86400000).toISOString().slice(0, 10)
    const defaultStart = mode === 'day' ? today :
      new Date(Date.parse(today + 'T12:00:00Z') - 6 * 86400000).toISOString().slice(0, 10)
    const window = periods(body.dateRange)
    const attribution = parseAttributionFilter(body)
    const db = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '')
    // Recorte first-touch: null = sem filtro. Com filtro, mensagens sem user_id saem.
    const allowed = await resolveAttributedUserIds(db, attribution)
    const messages = keepAllowed(await fetchRows<UserMessage>(db, 'chat_messages', 'user_id, created_at', query => {
      query = query.eq('sender', 'user')
      if (body.dateRange) return query.gte('created_at', window.from.toISOString()).lt('created_at', window.to.toISOString())
      // Fetch a safe superset; exact local-calendar boundaries are applied below.
      return mode === 'total' ? query.lt('created_at', now.toISOString()) :
        query.gte('created_at', new Date(Date.parse(defaultStart + 'T00:00:00Z') - 86400000).toISOString()).lt('created_at', now.toISOString())
    }), allowed, 'user_id')
    const selected = messages.filter(message => body.dateRange ||
      (local(message.created_at).day >= (mode === 'total' ? '0000' : defaultStart) && local(message.created_at).day < tomorrow))
    const buckets = new Map<string, { label: string; mensagens: number; users: Set<string> }>()
    const add = (key: string, label: string) => buckets.set(key, { label, mensagens: 0, users: new Set() })
    if (mode === 'day') {
      if (body.zoomHour === undefined) for (let hour = 0; hour < 24; hour++) add(String(hour), String(hour).padStart(2, '0') + 'h')
      else for (let minute = 0; minute < 60; minute += 15) add(String(minute), String(body.zoomHour).padStart(2, '0') + ':' + String(minute).padStart(2, '0'))
    } else {
      const first = body.dateRange ? local(window.from).day : mode === 'total' ?
        selected.map(message => local(message.created_at).day).sort()[0] ?? today : defaultStart
      const last = body.dateRange ? local(new Date(window.to.getTime() - 1)).day : today
      for (let day = first; day <= last; day = new Date(Date.parse(day + 'T12:00:00Z') + 86400000).toISOString().slice(0, 10)) {
        add(day, day.slice(8, 10) + '/' + day.slice(5, 7) + (first.slice(0, 4) !== last.slice(0, 4) ? '/' + day.slice(0, 4) : ''))
      }
    }
    for (const message of selected) {
      const time = local(message.created_at)
      if (mode === 'day' && body.zoomHour !== undefined && time.hour !== body.zoomHour) continue
      const key = mode !== 'day' ? time.day : String(body.zoomHour === undefined ? time.hour : Math.floor(time.minute / 15) * 15)
      const bucket = buckets.get(key)
      if (bucket) {
        bucket.mensagens++
        if (message.user_id) bucket.users.add(message.user_id)
      }
    }
    return jsonResponse([...buckets.values()].map(bucket => ({ label: bucket.label, mensagens: bucket.mensagens, usuarios: bucket.users.size })))
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Consulta indisponível'
    console.error('analytics-activity failed:', message)
    return jsonResponse({ error: message },
      message === 'Período inválido' || error instanceof SyntaxError || isAttributionFilterError(error) ? 400 : 500)
  }
})
