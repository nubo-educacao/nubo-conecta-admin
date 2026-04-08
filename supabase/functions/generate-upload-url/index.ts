// Edge Function: generate-upload-url — Sprint 02 Wave 5 (Gap 4 Opção A)
// Receives { filename, bucket } from authenticated Admin client.
// Uses service_role to create a signed upload URL for the mec-csv-uploads bucket.
// Returns { signedUrl, path }.
// PLAYBOOK § 3: service_role key from env only — never hardcoded.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Verify caller is authenticated (JWT must be present)
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return new Response(
        JSON.stringify({ error: 'Missing or invalid Authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    const { filename, bucket = 'mec-csv-uploads' } = await req.json();

    if (!filename || typeof filename !== 'string') {
      return new Response(
        JSON.stringify({ error: 'filename is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    // Build storage path: timestamp prefix prevents collisions
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const path = `${timestamp}_${filename}`;

    // Use service_role to bypass RLS for Storage operations (Gap 4 Opção A)
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data, error } = await supabaseAdmin.storage
      .from(bucket)
      .createSignedUploadUrl(path);

    if (error) {
      return new Response(
        JSON.stringify({ error: `Failed to create signed URL: ${error.message}` }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    return new Response(
      JSON.stringify({ signedUrl: data.signedUrl, path }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: `Unexpected error: ${(err as Error).message}` }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
});
