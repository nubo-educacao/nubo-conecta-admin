import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

  try {
    // 1. Auth: verify the calling user
    const userClient = createClient(
      supabaseUrl,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const { data: { user } } = await userClient.auth.getUser()
    if (!user) throw new Error('Unauthorized')

    // Allow admin override: if body contains profile_id, use it (for Shadow Testing)
    let profileId = user.id
    try {
      const body = await req.json()
      if (body?.profile_id) {
        profileId = body.profile_id
      }
    } catch {
      // No body or invalid JSON — use authenticated user's ID
    }

    // 2. Service client (bypasses RLS)
    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // 3. Mark as processing
    await serviceClient
      .from('user_preferences')
      .update({ match_status: 'processing', last_match_at: new Date().toISOString() })
      .eq('user_id', profileId)

    // 4. Execute the match calculation synchronously via RPC
    const { data, error: rpcError } = await serviceClient.rpc('calculate_match', {
      p_profile_id: profileId,
    })

    if (rpcError) {
      // Mark error status
      await serviceClient
        .from('user_preferences')
        .update({ match_status: 'error' })
        .eq('user_id', profileId)
      throw rpcError
    }

    // 5. Mark as ready
    await serviceClient
      .from('user_preferences')
      .update({ match_status: 'ready' })
      .eq('user_id', profileId)

    return new Response(
      JSON.stringify({
        message: 'Match calculation completed',
        profileId,
        status: 'ready',
        matchCount: Array.isArray(data) ? data.length : 0,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    )
  } catch (error) {
    return new Response(JSON.stringify({ error: (error as Error).message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
