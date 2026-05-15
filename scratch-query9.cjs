const url = 'https://yfgciamhzjvarwgzosto.supabase.co/rest/v1/?apikey=sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns';
const headers = {
  apikey: 'sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns',
  Authorization: `Bearer sb_publishable_OTHxmEItZ1qVThDs-IbJHQ_sqzSR_ns`
};
fetch(url, { headers })
  .then(r => r.json())
  .then(data => console.log(Object.keys(data.definitions)));
