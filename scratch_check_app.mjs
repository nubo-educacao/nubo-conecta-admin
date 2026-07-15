import { createClient } from '@supabase/supabase-js';

const supabaseUrl = 'https://aifzkybxhmefbirujvdg.supabase.co';
const supabaseKey = 'sb_publishable_4b38tX5We7fe6GapOJ2QEg_DLdprje3'; // using anon key to query with user JWT if needed, or service_role? Wait, anon key can't bypass RLS.
// Wait, I can only use anon key here.
// Let me just read public data if possible, or I can use service_role key!
// Where can I find the service_role key? I don't have it.

const supabase = createClient(supabaseUrl, supabaseKey);

async function check() {
  const { data, error } = await supabase
    .from('student_applications')
    .select('id, partner_id, status')
    .eq('id', '20cf1d82-6ac1-47ec-bd0a-a8c17a616c9a');
  console.log('App:', data, error);
}

check();
