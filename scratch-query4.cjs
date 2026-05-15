const url = 'https://yfgciamhzjvarwgzosto.supabase.co/rest/v1/opportunities_sisu_vacancies?select=opportunity_id,tp_cota,qt_vagas_ofertadas&opportunity_id=in.(a4dfecdd-4d08-4959-a006-e08a486ab02f,5dbbd00f-c55b-4526-a637-42b683e24305)';
const headers = {
  apikey: 'sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns',
  Authorization: `Bearer sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns`
};
fetch(url, { headers })
  .then(r => r.json())
  .then(console.log);
