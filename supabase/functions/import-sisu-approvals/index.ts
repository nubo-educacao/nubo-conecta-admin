// Edge Function: import-sisu-approvals — Sprint 8.0
// ETL: Agregar rawsisuapprovals2026 → opportunities_sisu_approvals
// Agrega por (opportunity_id, tipo_concorrencia): COUNT, MIN, MAX, AVG nota
// Matching: NO_IES (SG_IES) + NO_CAMPUS + NO_CURSO + DS_TURNO → opportunities (sisu)
// Após inserção, faz REFRESH MATERIALIZED VIEW CONCURRENTLY v_unified_opportunities.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return new Response(
        JSON.stringify({ error: 'Missing or invalid Authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    const { year } = await req.json().catch(() => ({}));
    const targetYear = typeof year === 'number' ? year : 2026;

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data, error } = await supabaseAdmin.rpc('etl_sisu_approvals', { p_year: targetYear });

    if (error) {
      return new Response(
        JSON.stringify({ error: `ETL failed: ${error.message}` }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    // Approvals are not in the matview (per design), but refresh anyway for consistency
    await supabaseAdmin.rpc('refresh_unified_opportunities');

    return new Response(
      JSON.stringify({ processed: data?.processed ?? 0, errors: data?.errors ?? [] }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: `Unexpected error: ${(err as Error).message}` }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
});
