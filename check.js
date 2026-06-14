import { createClient } from '@supabase/supabase-js'

const supabaseUrl = 'https://yfgciamhzjvarwgzosto.supabase.co'
const supabaseKey = 'sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns'
const supabase = createClient(supabaseUrl, supabaseKey)

async function main() {
  const { data, error } = await supabase.from('etl_run_logs').select('*').order('started_at', {ascending: false}).limit(5)
  console.log(data)
}
main()
