import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
dotenv.config();

const supabase = createClient(process.env.VITE_SUPABASE_URL, process.env.VITE_SUPABASE_SERVICE_ROLE_KEY);

async function testEtl() {
    console.log("Fetching program id...");
    const { data: programs, error: progErr } = await supabase.from('programs').select('id').limit(1);
    if (progErr) { console.error(progErr); return; }
    
    const programId = programs[0].id;
    console.log("Program ID:", programId);
    console.log("Calling etl_import_prouni...");
    
    const start = Date.now();
    const { data, error } = await supabase.rpc('etl_import_prouni', {
        p_program_id: programId,
        p_limit: 100,
        p_offset: 0
    });
    
    console.log("Time taken:", (Date.now() - start) / 1000, "seconds");
    console.log("Data:", data);
    console.log("Error:", error);
}

testEtl();
