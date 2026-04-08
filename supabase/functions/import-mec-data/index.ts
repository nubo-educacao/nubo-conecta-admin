// Edge Function: import-mec-data — Sprint 02 Wave 5
// Receives { fileKey, importType } from authenticated Admin client.
// Streams the CSV file from Storage, parses it as JSON chunks,
// and calls the appropriate process_mec_*_csv RPC.
// Returns { processed: number, errors: string[] }.
//
// importType dispatch:
//   'institutions' → process_mec_institutions_csv
//   'campus'       → process_mec_campus_csv
//   'courses'      → process_mec_courses_csv
//
// PLAYBOOK § 3: service_role key from env. Fail Fast on unknown importType.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

type ImportType = 'institutions' | 'campus' | 'courses';

const RPC_MAP: Record<ImportType, string> = {
  institutions: 'process_mec_institutions_csv',
  campus:       'process_mec_campus_csv',
  courses:      'process_mec_courses_csv',
};

const CHUNK_SIZE = 500; // Process 500 records per RPC call to avoid timeout

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

    const { fileKey, importType } = await req.json();

    if (!fileKey || typeof fileKey !== 'string') {
      return new Response(
        JSON.stringify({ error: 'fileKey is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    if (!importType || !(importType in RPC_MAP)) {
      return new Response(
        JSON.stringify({ error: `importType must be one of: ${Object.keys(RPC_MAP).join(', ')}` }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // Download file from Storage
    const { data: fileData, error: downloadError } = await supabaseAdmin.storage
      .from('mec-csv-uploads')
      .download(fileKey);

    if (downloadError || !fileData) {
      return new Response(
        JSON.stringify({ error: `Failed to download file: ${downloadError?.message}` }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    // Parse file content as JSON array
    // The Edge Function expects the uploaded file to be a JSON array of records
    // (the Admin UI or a pre-processing step converts CSV → JSON before upload)
    const fileText = await fileData.text();
    let records: unknown[];

    try {
      records = JSON.parse(fileText);
      if (!Array.isArray(records)) throw new Error('File content must be a JSON array');
    } catch (parseErr) {
      return new Response(
        JSON.stringify({ error: `Invalid file format: ${(parseErr as Error).message}` }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    const rpcName = RPC_MAP[importType as ImportType];
    let totalProcessed = 0;
    const allErrors: string[] = [];

    // Process in chunks to avoid RPC timeout
    for (let i = 0; i < records.length; i += CHUNK_SIZE) {
      const chunk = records.slice(i, i + CHUNK_SIZE);

      const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc(rpcName, {
        p_records: chunk,
      });

      if (rpcError) {
        allErrors.push(`Chunk ${Math.floor(i / CHUNK_SIZE)}: ${rpcError.message}`);
        continue;
      }

      if (rpcResult) {
        totalProcessed += rpcResult.processed ?? 0;
        const chunkErrors: Array<{ record: unknown; error: string }> = rpcResult.errors ?? [];
        chunkErrors.forEach((e) => {
          allErrors.push(`Record error: ${e.error}`);
        });
      }
    }

    return new Response(
      JSON.stringify({ processed: totalProcessed, errors: allErrors }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: `Unexpected error: ${(err as Error).message}` }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
});
