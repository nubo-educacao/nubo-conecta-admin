// Restored from deployed v106; corrected user-only activity and real period comparisons.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { authorizeBackoffice, corsHeaders, jsonResponse, periods, change, fetchRows, sessionCounts,
  type AnalyticsRange, type UserMessage } from '../_shared/command-center.ts'
import { fetchUserMessageStats } from './user-message-stats.ts'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders })
  try {
    const denied = await authorizeBackoffice(req, createClient)
    if (denied) return denied
    const payload: { dateRange?: AnalyticsRange } = req.method === 'POST' ? await req.json() : {}
    const { from, to, previousFrom } = periods(payload?.dateRange)
    const db = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '')
    const [registered, messages, favorites, preferences, profiles, volume] = await Promise.all([
      db.auth.admin.listUsers({ page: 1, perPage: 1 }),
      fetchRows<UserMessage>(db, 'chat_messages', 'user_id, created_at', query =>
        query.eq('sender', 'user').gte('created_at', previousFrom.toISOString()).lt('created_at', to.toISOString())),
      fetchRows<{ user_id: string; created_at: string }>(db, 'user_favorites', 'user_id, created_at'),
      fetchRows<{ user_id: string; updated_at: string }>(db, 'user_preferences', 'user_id, updated_at', query =>
        query.gte('updated_at', previousFrom.toISOString()).lt('updated_at', to.toISOString())),
      fetchRows<{ id: string; full_name: string }>(db, 'user_profiles', 'id, full_name'),
      fetchUserMessageStats(db, payload?.dateRange),
    ])
    if (registered.error || typeof registered.data?.total !== 'number') throw new Error('Contagem de usuários indisponível')
    const inWindow = (timestamp: string, start: Date, end: Date) => Date.parse(timestamp) >= start.getTime() && Date.parse(timestamp) < end.getTime()
    const currentMessages = messages.filter(message => inWindow(message.created_at, from, to))
    const previousMessages = messages.filter(message => inWindow(message.created_at, previousFrom, from))
    const activity = (rows: UserMessage[], start: Date, end: Date) => {
      const messageUsers = new Set(rows.map(row => row.user_id).filter(Boolean))
      const catalogUsers = new Set<string>()
      for (const row of favorites) if (row.user_id && inWindow(row.created_at, start, end) && !messageUsers.has(row.user_id)) catalogUsers.add(row.user_id)
      for (const row of preferences) if (row.user_id && inWindow(row.updated_at, start, end) && !messageUsers.has(row.user_id)) catalogUsers.add(row.user_id)
      return { messageUsers: messageUsers.size, catalogUsers: catalogUsers.size, active: messageUsers.size + catalogUsers.size }
    }
    const current = activity(currentMessages, from, to), previous = activity(previousMessages, previousFrom, from)
    const currentSessions = sessionCounts(currentMessages), previousSessions = sessionCounts(previousMessages)
    const names = new Map(profiles.map(profile => [profile.id, profile.full_name]))
    const powerUsersList = [...currentSessions].filter(([, count]) => count >= 2)
      .map(([id, count]) => ({ userId: id, userName: names.get(id) || 'Usuário sem perfil', userPhone: '', accessCount: count }))
      .sort((a, b) => b.accessCount - a.accessCount || a.userId.localeCompare(b.userId))
    const previousPowerUsers = [...previousSessions.values()].filter(count => count >= 2).length
    const currentFavorites = favorites.filter(row => inWindow(row.created_at, from, to)).length
    const previousFavorites = favorites.filter(row => inWindow(row.created_at, previousFrom, from)).length
    return jsonResponse({
      totalRegistered: registered.data.total,
      activeUsers: current.active, activeUsersWithMessages: current.messageUsers, catalogUsers: current.catalogUsers,
      activeUsersChange: change(current.active, previous.active), catalogUsersChange: change(current.catalogUsers, previous.catalogUsers),
      ...volume, totalFavorites: payload?.dateRange ? currentFavorites : favorites.length,
      favoritesChange: change(currentFavorites, previousFavorites),
      powerUsers: powerUsersList.length, powerUsersChange: change(powerUsersList.length, previousPowerUsers),
      powerUsersList: powerUsersList.slice(0, 50),
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Consulta indisponível'
    console.error('analytics-stats failed:', message)
    return jsonResponse({ error: message }, message === 'Período inválido' || error instanceof SyntaxError ? 400 : 500)
  }
})
