import { createClient } from '@supabase/supabase-js';

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || 'http://127.0.0.1:54321';
const supabaseKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;

// Use the service role key to have permissions to query raw sql if needed, but RPC is better
// Actually, let's just make a select to v_unified_institutions and see what error it throws.

async function check() {
  if (!supabaseKey) {
    console.log("No ANON KEY. Please run with NEXT_PUBLIC_SUPABASE_ANON_KEY set.");
    return;
  }
  const supabase = createClient(supabaseUrl, supabaseKey);
  const { data, error } = await supabase
    .from('v_unified_institutions')
    .select('*')
    .limit(1);

  if (error) {
    console.error("Query Error:", error);
  } else {
    console.log("Query Success. Columns returned:");
    if (data && data.length > 0) {
      console.log(Object.keys(data[0]));
    }
  }
}
check();
