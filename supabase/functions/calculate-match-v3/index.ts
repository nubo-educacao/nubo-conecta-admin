/**
 * Edge Function: calculate-match-v3
 *
 * Called asynchronously by the DB trigger `trg_enqueue_calculate_match_v3` via pg_net,
 * or directly from the frontend UI (Gerar Match / Refazer Match button).
 *
 * Responsibilities:
 *  1. Resolve the caller's profile_id (from JWT or request body).
 *  2. Delegate the heavy scoring to the `calculate_match` V3 RPC which:
 *     - Reads best ENEM scores (last 3 years, weighted by SISU per-area pesos)
 *     - Applies income eligibility cuts (ProUni ≤ 1.5 SM, FIES ≤ 3 SM)
 *     - Scores distance via Haversine
 *     - DELETEs old rows and bulk-INSERTs new results into user_opportunity_matches
 *  3. Update match_status on user_preferences (processing → ready / error).
 *
 * BDD covered:
 *  - Given the Edge Function receives a user profile
 *    When calculating the rank
 *    Then it considers SISU weights, income eligibility, and distance
 *    And materializes the result in the user_opportunity_matches table
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req: Request): Promise<Response> => {
  // ── Preflight ──────────────────────────────────────────────────────────────
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS })
  }

  const supabaseUrl     = Deno.env.get('SUPABASE_URL')!
  const serviceRoleKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const anonKey         = Deno.env.get('SUPABASE_ANON_KEY')!

  // ── Service client (bypasses RLS — used for writes) ────────────────────────
  const serviceClient = createClient(supabaseUrl, serviceRoleKey)

  let profileId: string | null = null

  try {
    // ── 1. Resolve profile_id ────────────────────────────────────────────────
    // Priority order:
    //   a) JWT bearer token (direct call from the app)
    //   b) profile_id field in JSON body (pg_net trigger call uses service key)

    const authHeader = req.headers.get('Authorization') ?? ''

    // Try JWT first
    if (authHeader.startsWith('Bearer ') && authHeader !== `Bearer ${serviceRoleKey}`) {
      const userClient = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: authHeader } },
      })
      const { data: { user }, error: authError } = await userClient.auth.getUser()
      if (authError || !user) throw new Error('Unauthorized')
      profileId = user.id
    }

    // Fall back to body (called by pg_net trigger or admin override)
    if (!profileId) {
      let body: Record<string, unknown> = {}
      try {
        body = await req.json()
      } catch {
        // empty body is acceptable — profile_id stays null
      }
      if (typeof body.profile_id === 'string') profileId = body.profile_id
    }

    if (!profileId) throw new Error('Could not resolve profile_id from JWT or request body')

    // ── 2. Mark as processing ────────────────────────────────────────────────
    await serviceClient
      .from('user_preferences')
      .update({ match_status: 'processing', last_match_at: new Date().toISOString() })
      .eq('user_id', profileId)

    // ── 3. Run V3 calculate_match RPC ────────────────────────────────────────
    //
    // The RPC:
    //   • Picks the best ENEM year using per-area SISU pesos from opportunitiessisuvacancies
    //   • Applies income eligibility cuts (ProUni ≤ 1.5 SM, FIES ≤ 3 SM)
    //   • Scores distance via Haversine (user lat/lon from user_preferences)
    //   • Adds partner & idle-vacancy boosts from match_config
    //   • Aggregates MAX score per course (multi-opportunity → one card per course)
    //   • DELETEs old user_opportunity_matches rows for this profile, then bulk-INSERTs new ones
    //
    // calculate_match V3 returns VOID — results are in user_opportunity_matches
    const { error: rpcError } = await serviceClient.rpc('calculate_match', {
      p_profile_id: profileId,
    })

    if (rpcError) {
      await serviceClient
        .from('user_preferences')
        .update({ match_status: 'error' })
        .eq('user_id', profileId)

      throw rpcError
    }

    // ── 4. Mark as ready ─────────────────────────────────────────────────────
    await serviceClient
      .from('user_preferences')
      .update({ match_status: 'ready', last_match_at: new Date().toISOString() })
      .eq('user_id', profileId)

    return new Response(
      JSON.stringify({ status: 'ready', profileId }),
      { headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }, status: 200 },
    )
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)

    // Best-effort: mark error state if we know the profile
    if (profileId) {
      await serviceClient
        .from('user_preferences')
        .update({ match_status: 'error' })
        .eq('user_id', profileId)
        .catch(() => {/* ignore secondary failure */})
    }

    return new Response(
      JSON.stringify({ error: message }),
      { headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' }, status: 400 },
    )
  }
})
