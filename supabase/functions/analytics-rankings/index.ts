import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { authorizeBackoffice, periods, fetchRows, sessionCounts, type UserMessage } from '../_shared/command-center.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// Helper function to fetch all records with pagination
async function fetchAllRecords<T>(
  supabase: any,
  table: string,
  selectFields: string,
  filters?: { column: string; operator: string; value: string }[],
  orderBy?: { column: string; ascending: boolean }
): Promise<T[]> {
  const PAGE_SIZE = 1000
  let allData: T[] = []
  let offset = 0
  let hasMore = true

  while (hasMore) {
    let query = supabase
      .from(table)
      .select(selectFields)
      .range(offset, offset + PAGE_SIZE - 1)

    if (filters) {
      for (const filter of filters) {
        if (filter.operator === 'gte') {
          query = query.gte(filter.column, filter.value)
        } else if (filter.operator === 'not.is') {
          query = query.not(filter.column, 'is', null)
        }
      }
    }

    query = query.order(orderBy?.column ?? 'id', { ascending: orderBy?.ascending ?? true })

    const { data, error } = await query

    if (error) {
      throw new Error(error.message ?? 'Consulta indisponível')
    }

    if (data && data.length > 0) {
      allData = allData.concat(data as T[])
      offset += PAGE_SIZE
      hasMore = data.length === PAGE_SIZE
    } else {
      hasMore = false
    }
  }

  return allData
}

// Normalize city names to remove duplicates like "São Paulo" vs "São Paulo - SP"
function normalizeCity(city: string): string {
  if (!city) return ''
  
  // Remove state suffix patterns like " - SP", " - RJ", etc.
  let normalized = city.trim()
  const statePattern = /\s*-\s*[A-Z]{2}$/i
  normalized = normalized.replace(statePattern, '')
  
  // Capitalize first letter of each word
  return normalized.split(' ').map(word => 
    word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()
  ).join(' ')
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    const denied = await authorizeBackoffice(req, createClient)
    if (denied) return denied
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    let body: { type?: string; dateRange?: { from: string; to: string } } = {}
    let type = 'users'
    const url = new URL(req.url)
    
    try {
      body = await req.json()
      type = body.type || url.searchParams.get('type') || 'users'
    } catch (error) {
      if (req.method === 'POST') throw error
      type = url.searchParams.get('type') || 'users'
    }
    
    console.log('Analytics rankings - type:', type)

    if (type === 'users') {
      const { from, to } = periods(body.dateRange)
      const messages = await fetchRows<UserMessage>(supabase, 'chat_messages', 'user_id, created_at', query =>
        query.eq('sender', 'user').gte('created_at', from.toISOString()).lt('created_at', to.toISOString()))
      const counts = new Map<string, number>()
      for (const message of messages) if (message.user_id) counts.set(message.user_id, (counts.get(message.user_id) ?? 0) + 1)
      if (counts.size === 0) return new Response('[]', { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
      const [profiles, favorites] = await Promise.all([
        fetchRows<{ id: string; full_name: string }>(supabase, 'user_profiles', 'id, full_name'),
        fetchRows<{ user_id: string }>(supabase, 'user_favorites', 'user_id'),
      ])
      const names = new Map(profiles.map(profile => [profile.id, profile.full_name]))
      const favoriteCounts = new Map<string, number>()
      for (const favorite of favorites) if (favorite.user_id) favoriteCounts.set(favorite.user_id, (favoriteCounts.get(favorite.user_id) ?? 0) + 1)
      const sessions = sessionCounts(messages)
      const topUsers = [...counts].map(([id, count]) => ({
        id, name: names.get(id) || 'Usuário sem perfil', messages: count,
        favorites: favoriteCounts.get(id) ?? 0, sessions: sessions.get(id) ?? 0, score: count,
      })).sort((a, b) => b.messages - a.messages || a.id.localeCompare(b.id)).slice(0, 100)
      return new Response(JSON.stringify(topUsers), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (type === 'locations') {
      // This shows where users LIVE (from user_profiles.city)
      interface Profile { city: string | null }
      
      const profiles = await fetchAllRecords<Profile>(
        supabase,
        'user_profiles',
        'city',
        [{ column: 'city', operator: 'not.is', value: 'null' }]
      )

      const locationCounts = new Map<string, number>()
      
      for (const p of profiles) {
        if (p.city) {
          const normalized = normalizeCity(p.city)
          if (normalized) {
            locationCounts.set(normalized, (locationCounts.get(normalized) || 0) + 1)
          }
        }
      }

      const locations = Array.from(locationCounts.entries())
        .map(([name, count]) => ({ name, count }))
        .sort((a, b) => b.count - a.count)
        .slice(0, 10)

      console.log('Analytics rankings (locations) response:', locations.length, 'locations')

      return new Response(JSON.stringify(locations), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (type === 'courses') {
      interface Preference { course_interest: string[] | null }
      
      const preferences = await fetchAllRecords<Preference>(
        supabase,
        'user_preferences',
        'course_interest',
        [{ column: 'course_interest', operator: 'not.is', value: 'null' }]
      )

      const courseCounts = new Map<string, number>()
      
      // Normalize course names to handle case differences
      const normalizeCourse = (course: string): string => {
        if (!course) return ''
        // Capitalize first letter of each word
        return course.trim().split(' ').map(word => 
          word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()
        ).join(' ')
      }
      
      for (const p of preferences) {
        if (p.course_interest && Array.isArray(p.course_interest)) {
          for (const course of p.course_interest) {
            if (course && course.trim()) {
              const normalized = normalizeCourse(course)
              if (normalized) {
                courseCounts.set(normalized, (courseCounts.get(normalized) || 0) + 1)
              }
            }
          }
        }
      }

      const courses = Array.from(courseCounts.entries())
        .map(([name, searches]) => ({ name, searches }))
        .sort((a, b) => b.searches - a.searches)
        .slice(0, 20)

      console.log('Analytics rankings (courses) response:', courses.length, 'courses')

      return new Response(JSON.stringify(courses), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (type === 'preferences') {
      interface Preference { program_preference: string | null }
      
      const preferences = await fetchAllRecords<Preference>(
        supabase,
        'user_preferences',
        'program_preference',
        [{ column: 'program_preference', operator: 'not.is', value: 'null' }]
      )

      const prefCounts = new Map<string, number>()
      
      for (const p of preferences) {
        if (p.program_preference) {
          prefCounts.set(p.program_preference, (prefCounts.get(p.program_preference) || 0) + 1)
        }
      }

      const total = preferences.length || 1

      const prefs = Array.from(prefCounts.entries())
        .map(([name, count]) => ({ 
          name, 
          value: Math.round((count / total) * 100)
        }))
        .sort((a, b) => b.value - a.value)
        .slice(0, 5)

      console.log('Analytics rankings (preferences) response:', prefs.length, 'preferences')

      return new Response(JSON.stringify(prefs), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (type === 'location_preferences') {
      // This shows where users WANT TO STUDY (from user_preferences.location_preference)
      interface Preference { location_preference: string | null }
      
      const preferences = await fetchAllRecords<Preference>(
        supabase,
        'user_preferences',
        'location_preference',
        [{ column: 'location_preference', operator: 'not.is', value: 'null' }]
      )

      const locationCounts = new Map<string, number>()
      
      for (const p of preferences) {
        if (p.location_preference) {
          const loc = normalizeCity(p.location_preference)
          if (loc) {
            locationCounts.set(loc, (locationCounts.get(loc) || 0) + 1)
          }
        }
      }

      const locations = Array.from(locationCounts.entries())
        .map(([name, count]) => ({ name, count }))
        .sort((a, b) => b.count - a.count)
        .slice(0, 8)

      console.log('Analytics rankings (location_preferences) response:', locations.length, 'locations')

      return new Response(JSON.stringify(locations), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    return new Response(JSON.stringify({ error: 'Invalid type parameter' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (error) {
    console.error('Error in analytics-rankings:', error)
    const message = error instanceof Error ? error.message : 'Unknown error'
    return new Response(JSON.stringify({ error: message }), {
      status: message === 'Período inválido' || error instanceof SyntaxError ? 400 : 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
