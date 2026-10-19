// NUB-RD-93: the first-touch cut, counts and tie order run in SQL
// (cc_rankings_aggregate); this Edge only authorizes, validates, normalizes
// labels and cuts the top N, exactly as before.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { authorizeBackoffice, periods, callAggregate } from '../_shared/command-center.ts'
import { parseAttributionFilter, attributionRpcArgs, isAttributionFilterError } from '../_shared/attribution-filter.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (data: unknown) => new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

const TYPES = ['users', 'locations', 'courses', 'preferences', 'location_preferences']

interface RankedUser { id: string; name: string; messages: number; favorites: number; sessions: number; score: number }
// Raw values grouped in SQL, in order of first appearance (rows by id, array items in order).
interface RawGroups { total: number; groups: { value: string; count: number }[] }

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

// Normalize course names to handle case differences
function normalizeCourse(course: string): string {
  if (!course) return ''
  // Capitalize first letter of each word
  return course.trim().split(' ').map(word => 
    word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()
  ).join(' ')
}

// Same Map-insertion + stable-sort semantics the paginated version had.
function countBy(groups: RawGroups['groups'], label: (value: string) => string) {
  const counts = new Map<string, number>()
  for (const group of groups) {
    const name = label(group.value)
    if (name) counts.set(name, (counts.get(name) || 0) + group.count)
  }
  return Array.from(counts.entries())
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

    // Recorte first-touch por campanha/divulgador; sem filtro, resultados como antes.
    const attribution = parseAttributionFilter(body)
    if (!TYPES.includes(type)) {
      return new Response(JSON.stringify({ error: 'Invalid type parameter' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
    const range = type === 'users' ? periods(body.dateRange) : null
    const ranking = await callAggregate<RankedUser[] | RawGroups>(supabase, 'cc_rankings_aggregate', {
      p_type: type,
      p_from: range ? range.from.toISOString() : null,
      p_to: range ? range.to.toISOString() : null,
      ...attributionRpcArgs(attribution),
    })

    if (type === 'users') {
      return json((ranking as RankedUser[]).map(user => ({ id: user.id, name: user.name, messages: user.messages,
        favorites: user.favorites, sessions: user.sessions, score: user.score })))
    }

    const { total, groups } = ranking as RawGroups

    if (type === 'locations') {
      // This shows where users LIVE (from user_profiles.city)
      const locations = countBy(groups, normalizeCity)
        .map(([name, count]) => ({ name, count }))
        .sort((a, b) => b.count - a.count)
        .slice(0, 10)
      console.log('Analytics rankings (locations) response:', locations.length, 'locations')
      return json(locations)
    }

    if (type === 'courses') {
      const courses = countBy(groups, course => course && course.trim() ? normalizeCourse(course) : '')
        .map(([name, searches]) => ({ name, searches }))
        .sort((a, b) => b.searches - a.searches)
        .slice(0, 20)
      console.log('Analytics rankings (courses) response:', courses.length, 'courses')
      return json(courses)
    }

    if (type === 'preferences') {
      const prefTotal = total || 1
      const prefs = countBy(groups, value => value)
        .map(([name, count]) => ({ 
          name, 
          value: Math.round((count / prefTotal) * 100)
        }))
        .sort((a, b) => b.value - a.value)
        .slice(0, 5)
      console.log('Analytics rankings (preferences) response:', prefs.length, 'preferences')
      return json(prefs)
    }

    // location_preferences: where users WANT TO STUDY (from user_preferences.location_preference)
    const locations = countBy(groups, normalizeCity)
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 8)
    console.log('Analytics rankings (location_preferences) response:', locations.length, 'locations')
    return json(locations)
  } catch (error) {
    console.error('Error in analytics-rankings:', error)
    const message = error instanceof Error ? error.message : 'Unknown error'
    return new Response(JSON.stringify({ error: message }), {
      status: message === 'Período inválido' || error instanceof SyntaxError || isAttributionFilterError(error) ? 400 : 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
