import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  'https://yfgciamhzjvarwgzosto.supabase.co',
  'sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns'
);

async function check() {
  const { data, error } = await supabase
    .from('v_unified_institutions')
    .select('*')
    .limit(1);

  if (error) {
    console.error("Query Error:", error);
  } else {
    console.log("Query Success. Columns returned:");
    if (data && data.length > 0) {
      console.log(Object.keys(data[0]).join(', '));
    }
  }
}
check();
