const url = process.env.NEXT_PUBLIC_SUPABASE_URL + '/rest/v1/opportunities?select=id,course_id,shift,concurrency_type,concurrency_tags&limit=20';
const headers = {
  apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  Authorization: `Bearer ${process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY}`
};
fetch(url, { headers })
  .then(r => r.json())
  .then(console.log);
