// Restored from deployed v106; corrected user-only activity and real period comparisons.
// NUB-RD-93: counts and the first-touch cut run in SQL (cc_stats_aggregate); this
// Edge only authorizes, validates and shapes the response (same keys and math).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { authorizeBackoffice, corsHeaders, jsonResponse, periods, change, callAggregate,
  type AnalyticsRange } from '../_shared/command-center.ts'
import { parseAttributionFilter, attributionRpcArgs, isAttributionFilterError } from '../_shared/attribution-filter.ts'

interface StatsAggregate {
  total_registered: number | null
  current_messages: number; previous_messages: number; history_messages: number | null
  message_users: number; previous_message_users: number
  catalog_users: number; previous_catalog_users: number
  current_favorites: number; previous_favorites: number; history_favorites: number | null
  power_users: number; previous_power_users: number
  power_users_list: { user_id: string; user_name: string; access_count: number }[]
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders })
  try {
    const denied = await authorizeBackoffice(req, createClient)
    if (denied) return denied
    const payload: { dateRange?: AnalyticsRange } = req.method === 'POST' ? await req.json() : {}
    const { from, to, previousFrom } = periods(payload?.dateRange)
    const attribution = parseAttributionFilter(payload)
    const db = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '')
    // Sem recorte, "cadastros" continua vindo do Auth; com recorte, perfis do recorte.
    const [registered, stats] = await Promise.all([
      attribution ? Promise.resolve(null) : db.auth.admin.listUsers({ page: 1, perPage: 1 }),
      callAggregate<StatsAggregate>(db, 'cc_stats_aggregate', {
        p_from: from.toISOString(), p_to: to.toISOString(), p_prev_from: previousFrom.toISOString(),
        // Sem período, "Total de Mensagens/Favoritos" é o histórico (do recorte, se houver).
        p_with_history: !payload?.dateRange,
        ...attributionRpcArgs(attribution),
      }),
    ])
    if (!attribution && (registered?.error || typeof registered?.data?.total !== 'number')) throw new Error('Contagem de usuários indisponível')
    const active = stats.message_users + stats.catalog_users
    const previousActive = stats.previous_message_users + stats.previous_catalog_users
    return jsonResponse({
      totalRegistered: attribution ? stats.total_registered : registered.data.total,
      activeUsers: active, activeUsersWithMessages: stats.message_users, catalogUsers: stats.catalog_users,
      activeUsersChange: change(active, previousActive), catalogUsersChange: change(stats.catalog_users, stats.previous_catalog_users),
      totalMessages: payload?.dateRange ? stats.current_messages : stats.history_messages,
      messagesChange: change(stats.current_messages, stats.previous_messages),
      totalFavorites: payload?.dateRange ? stats.current_favorites : stats.history_favorites,
      favoritesChange: change(stats.current_favorites, stats.previous_favorites),
      powerUsers: stats.power_users, powerUsersChange: change(stats.power_users, stats.previous_power_users),
      powerUsersList: stats.power_users_list.map(user =>
        ({ userId: user.user_id, userName: user.user_name, userPhone: '', accessCount: user.access_count })),
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Consulta indisponível'
    console.error('analytics-stats failed:', message)
    return jsonResponse({ error: message },
      message === 'Período inválido' || error instanceof SyntaxError || isAttributionFilterError(error) ? 400 : 500)
  }
})
