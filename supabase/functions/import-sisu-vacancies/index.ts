// Edge Function: import-sisu-vacancies — Sprint 8.0
// Re-import de vagas SisU: rawsisuvacancies2026 → opportunities_sisu_vacancies
// Usada para re-importações futuras (ex: SisU 2026.2).
// A tabela já está populada (113k rows de importação anterior).
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

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data, error } = await supabaseAdmin.rpc('etl_sisu_vacancies_2026');

    if (error) {
      return new Response(
        JSON.stringify({ error: `ETL failed: ${error.message}` }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

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
