const url = 'https://yfgciamhzjvarwgzosto.supabase.co/rest/v1/rpc/etl_prouni_vacancies';
const headers = {
  apikey: 'sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns',
  Authorization: `Bearer sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns`,
  'Content-Type': 'application/json'
};
fetch(url, { method: 'POST', headers })
  .then(r => r.text())
  .then(console.log);
