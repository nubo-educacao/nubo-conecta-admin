// Recovered from analytics-stats v106 (production), source SHA256:
// bfc22ea8719826c19e66045af4981d9bf6adea3403bbea6c5ddc3fad4e5c4b65.
// Other legacy metrics are preserved; user-message volume has its own tested query.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { fetchUserMessageStats, type MessageDateRange } from './user-message-stats.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// Helper to fetch all rows with pagination
// deno-lint-ignore no-explicit-any
async function fetchAllRows<T>(
  supabase: any,
  table: string,
  select: string,
  filters?: { column: string; operator: string; value: string | boolean }[]
): Promise<T[]> {
  const allRows: T[] = []
  const pageSize = 1000
  let from = 0
  let hasMore = true

  while (hasMore) {
    let query = supabase.from(table).select(select).range(from, from + pageSize - 1)
    
    if (filters) {
      for (const f of filters) {
        if (f.operator === 'gte') query = query.gte(f.column, f.value)
        else if (f.operator === 'lt') query = query.lt(f.column, f.value)
        else if (f.operator === 'eq') query = query.eq(f.column, f.value)
      }
    }

    const { data, error } = await query
    if (error) throw error

    if (data && data.length > 0) {
      allRows.push(...(data as T[]))
      from += pageSize
      hasMore = data.length === pageSize
    } else {
      hasMore = false
    }
  }

  return allRows
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    const authorization = req.headers.get('Authorization')
    if (!authorization?.startsWith('Bearer ')) {
      return new Response(JSON.stringify({ error: 'Autenticação obrigatória' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
    const caller = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } }
    )
    const { data: identity, error: authError } = await caller.auth.getUser()
    if (authError || !identity.user) {
      return new Response(JSON.stringify({ error: 'Sessão inválida' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
    const { data: isAdmin, error: roleError } = await caller.rpc('is_backoffice_admin')
    if (roleError || isAdmin !== true) {
      return new Response(JSON.stringify({ error: 'Acesso restrito ao backoffice' }), {
        status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
    const payload: { dateRange?: MessageDateRange } = req.method === 'POST' ? await req.json() : {}
    const dateRange = payload?.dateRange
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const now = new Date()
    const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000)
    const fourteenDaysAgo = new Date(now.getTime() - 14 * 24 * 60 * 60 * 1000)
    const today = new Date()
    today.setHours(0, 0, 0, 0)
    const yesterday = new Date(today.getTime() - 24 * 60 * 60 * 1000)

    console.log('Fetching analytics data with full pagination...')

    // ========== PARALLEL QUERIES ==========
    const [
      authUsersResult,
      allMessagesResult,
      favoritesCurrentResult,
      favoritesPrevResult,
      preferencesCurrentResult,
      preferencesPrevResult,
      messageStats,
      totalFavoritesResult,
      favoritesThisWeekResult,
      favoritesPrevWeekResult,
      errorsTodayResult,
      errorsYesterdayResult,
      profilesResult,
    ] = await Promise.all([
      // 1. Total registered users
      supabase.auth.admin.listUsers({ page: 1, perPage: 1 }),
      
      // 2. ALL messages with pagination for session calculation
      fetchAllRows<{ user_id: string; created_at: string }>(
        supabase, 'chat_messages', 'user_id, created_at'
      ),
      
      // 3. Favorites current period (7d)
      fetchAllRows<{ user_id: string }>(
        supabase, 'user_favorites', 'user_id',
        [{ column: 'created_at', operator: 'gte', value: sevenDaysAgo.toISOString() }]
      ),
      
      // 4. Favorites previous period
      fetchAllRows<{ user_id: string }>(
        supabase, 'user_favorites', 'user_id',
        [
          { column: 'created_at', operator: 'gte', value: fourteenDaysAgo.toISOString() },
          { column: 'created_at', operator: 'lt', value: sevenDaysAgo.toISOString() }
        ]
      ),
      
      // 5. Preferences current period
      fetchAllRows<{ user_id: string }>(
        supabase, 'user_preferences', 'user_id',
        [{ column: 'updated_at', operator: 'gte', value: sevenDaysAgo.toISOString() }]
      ),
      
      // 6. Preferences previous period
      fetchAllRows<{ user_id: string }>(
        supabase, 'user_preferences', 'user_id',
        [
          { column: 'updated_at', operator: 'gte', value: fourteenDaysAgo.toISOString() },
          { column: 'updated_at', operator: 'lt', value: sevenDaysAgo.toISOString() }
        ]
      ),
      
      // Counts
      fetchUserMessageStats(supabase, dateRange, now),
      supabase.from('user_favorites').select('*', { count: 'exact', head: true }),
      supabase.from('user_favorites').select('*', { count: 'exact', head: true }).gte('created_at', sevenDaysAgo.toISOString()),
      supabase.from('user_favorites').select('*', { count: 'exact', head: true }).gte('created_at', fourteenDaysAgo.toISOString()).lt('created_at', sevenDaysAgo.toISOString()),
      supabase.from('agent_errors').select('*', { count: 'exact', head: true }).gte('created_at', today.toISOString()).eq('resolved', false),
      supabase.from('agent_errors').select('*', { count: 'exact', head: true }).gte('created_at', yesterday.toISOString()).lt('created_at', today.toISOString()).eq('resolved', false),
      supabase.from('user_profiles').select('id, full_name'),
    ])

    const totalRegisteredUsers = (authUsersResult as any).data?.total || 
      authUsersResult.data?.users?.length || 0

    console.log('Total messages fetched:', allMessagesResult.length)

    // ========== POWER USERS: Calculate sessions with 30-min gap ==========
    const userMessages = new Map<string, Date[]>()
    const recentMessageUserIds = new Set<string>()
    
    for (const msg of allMessagesResult) {
      if (!msg.user_id) continue
      
      const msgDate = new Date(msg.created_at)
      
      // Track all messages per user for session calculation
      if (!userMessages.has(msg.user_id)) {
        userMessages.set(msg.user_id, [])
      }
      userMessages.get(msg.user_id)!.push(msgDate)
      
      // Track recent (7d) users
      if (msgDate >= sevenDaysAgo) {
        recentMessageUserIds.add(msg.user_id)
      }
    }

    // Calculate sessions per user (30-min gap = new session)
    const userSessionCounts = new Map<string, number>()
    for (const [userId, timestamps] of userMessages) {
      // Sort timestamps
      timestamps.sort((a, b) => a.getTime() - b.getTime())
      
      let sessions = 1 // At least 1 session
      for (let i = 1; i < timestamps.length; i++) {
        const gap = (timestamps[i].getTime() - timestamps[i-1].getTime()) / (1000 * 60) // in minutes
        if (gap > 30) {
          sessions++
        }
      }
      userSessionCounts.set(userId, sessions)
    }

    // Power users = 2+ sessions
    const powerUsersList: { userId: string; userName: string; userPhone: string; accessCount: number }[] = []
    const profileMap = new Map<string, string>()
    profilesResult.data?.forEach(p => {
      profileMap.set(p.id, p.full_name || 'Usuário Anônimo')
    })

    for (const [userId, sessionCount] of userSessionCounts) {
      if (sessionCount >= 2) {
        powerUsersList.push({
          userId,
          userName: profileMap.get(userId) || 'Usuário Anônimo',
          userPhone: '',
          accessCount: sessionCount
        })
      }
    }

    // Sort by session count desc
    powerUsersList.sort((a, b) => b.accessCount - a.accessCount)
    const powerUsersCount = powerUsersList.length

    console.log('Power users (2+ sessions):', powerUsersCount)

    // ========== ACTIVE USERS (7d) ==========
    const activeUsersWithMessages = recentMessageUserIds.size

    // Catalog users = favorites/preferences but no messages in last 7d
    const catalogUserIds = new Set<string>()
    for (const row of favoritesCurrentResult) {
      if (row.user_id && !recentMessageUserIds.has(row.user_id)) {
        catalogUserIds.add(row.user_id)
      }
    }
    for (const row of preferencesCurrentResult) {
      if (row.user_id && !recentMessageUserIds.has(row.user_id)) {
        catalogUserIds.add(row.user_id)
      }
    }
    const catalogUsersCount = catalogUserIds.size
    const totalActiveUsers = activeUsersWithMessages + catalogUsersCount

    // Previous period
    const prevMessageUserIds = new Set<string>()
    for (const msg of allMessagesResult) {
      if (!msg.user_id) continue
      const msgDate = new Date(msg.created_at)
      if (msgDate >= fourteenDaysAgo && msgDate < sevenDaysAgo) {
        prevMessageUserIds.add(msg.user_id)
      }
    }
    
    const prevCatalogUserIds = new Set<string>()
    for (const row of favoritesPrevResult) {
      if (row.user_id && !prevMessageUserIds.has(row.user_id)) {
        prevCatalogUserIds.add(row.user_id)
      }
    }
    for (const row of preferencesPrevResult) {
      if (row.user_id && !prevMessageUserIds.has(row.user_id)) {
        prevCatalogUserIds.add(row.user_id)
      }
    }
    
    const catalogUsersPrev = prevCatalogUserIds.size
    const activeUsersPrev = prevMessageUserIds.size
    const totalActiveUsersPrev = activeUsersPrev + catalogUsersPrev

    // Previous power users count (approximate based on ratio)
    const powerUsersPrevCount = Math.round(powerUsersCount * (activeUsersPrev / Math.max(activeUsersWithMessages, 1)))

    const calcChange = (current: number, previous: number) => {
      if (previous === 0) return current > 0 ? 100 : 0
      return Math.round(((current - previous) / previous) * 100)
    }

    const response = {
      totalRegistered: totalRegisteredUsers,
      activeUsers: totalActiveUsers,
      activeUsersWithMessages: activeUsersWithMessages,
      catalogUsers: catalogUsersCount,
      activeUsersChange: calcChange(totalActiveUsers, totalActiveUsersPrev),
      catalogUsersChange: calcChange(catalogUsersCount, catalogUsersPrev),
      ...messageStats,
      totalFavorites: totalFavoritesResult.count || 0,
      favoritesChange: calcChange(favoritesThisWeekResult.count || 0, favoritesPrevWeekResult.count || 0),
      errorsToday: errorsTodayResult.count || 0,
      errorsChange: calcChange(errorsTodayResult.count || 0, errorsYesterdayResult.count || 0),
      powerUsers: powerUsersCount,
      powerUsersChange: calcChange(powerUsersCount, powerUsersPrevCount),
      powerUsersList: powerUsersList.slice(0, 50),
    }

    console.log('Analytics stats response:', {
      totalRegistered: totalRegisteredUsers,
      totalActive: totalActiveUsers,
      withMessages: activeUsersWithMessages,
      catalogOnly: catalogUsersCount,
      powerUsers: powerUsersCount,
      totalMessagesFetched: allMessagesResult.length
    })

    return new Response(JSON.stringify(response), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (error) {
    console.error('Error in analytics-stats:', error)
    const message = error instanceof Error ? error.message : 'Unknown error'
    return new Response(JSON.stringify({ error: message }), {
      status: message === 'Período inválido' || error instanceof SyntaxError ? 400 : 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
