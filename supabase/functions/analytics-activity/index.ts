// Canonical replacement for the deployed legacy activity handler.
// NUB-RD-93: buckets and the first-touch cut run in SQL (cc_activity_aggregate),
// in the requested time zone; this Edge only authorizes, validates and shapes.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { authorizeBackoffice, corsHeaders, jsonResponse, periods, callAggregate,
  type AnalyticsRange } from '../_shared/command-center.ts'
import { parseAttributionFilter, attributionRpcArgs, isAttributionFilterError } from '../_shared/attribution-filter.ts'

interface ActivityBucket { label: string; mensagens: number; usuarios: number }

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
    try {
      new Intl.DateTimeFormat('en-CA', { timeZone })
    } catch { return jsonResponse({ error: 'Fuso horário inválido' }, 400) }
    // Legacy callers without a global filter keep today's/last-seven-days/full-history views (in SQL).
    const window = periods(body.dateRange)
    const attribution = parseAttributionFilter(body)
    const db = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '')
    const buckets = await callAggregate<ActivityBucket[]>(db, 'cc_activity_aggregate', {
      p_mode: mode,
      p_from: body.dateRange ? window.from.toISOString() : null,
      p_to: body.dateRange ? window.to.toISOString() : null,
      p_time_zone: timeZone,
      p_zoom_hour: body.zoomHour ?? null,
      ...attributionRpcArgs(attribution),
    })
    return jsonResponse(buckets.map(bucket => ({ label: bucket.label, mensagens: bucket.mensagens, usuarios: bucket.usuarios })))
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Consulta indisponível'
    console.error('analytics-activity failed:', message)
    // A zone Intl accepts but Postgres does not know is still the caller's input.
    if (message === 'Fuso horário inválido') return jsonResponse({ error: message }, 400)
    return jsonResponse({ error: message },
      message === 'Período inválido' || error instanceof SyntaxError || isAttributionFilterError(error) ? 400 : 500)
  }
})
