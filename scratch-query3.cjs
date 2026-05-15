const url = 'https://yfgciamhzjvarwgzosto.supabase.co/rest/v1/opportunities?select=id,course_id,shift,concurrency_type,concurrency_tags&limit=20';
const headers = {
  apikey: 'sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns',
  Authorization: `Bearer sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns`
};
fetch(url, { headers })
  .then(r => r.json())
  .then(console.log);
