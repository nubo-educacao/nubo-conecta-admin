require('dotenv').config();
const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

async function run() {
  const { data: opps } = await supabase.from('opportunities').select('id, course_id, shift, concurrency_tags, opportunity_type').limit(20);
  console.log(opps);
}
run();
