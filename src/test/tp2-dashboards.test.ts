import {beforeEach,describe,it,expect,vi} from 'vitest';
const {rpc}=vi.hoisted(()=>({rpc:vi.fn()}));vi.mock('@/integrations/supabase/client',()=>({supabase:{rpc}}));
import {getPartnerFunnel} from '@/services/passportDashboardService';
import {getMecDashboard,cohortRate,getMecOpportunityVolumes,getMecVolumeInstitutions,mecRangeFromDashboard,type MecDashboardData} from '@/services/mecDashboardService';
beforeEach(()=>rpc.mockReset());
describe('TP-D B2B/MEC contracts',()=>{
 it('requests v2 with explicit half-open period',async()=>{
  const rows=[{total_card_clicks:9,total_unique_clicks:2,legacy_external_redirects:3,last_activity_at:null}];
  rpc.mockResolvedValue({data:rows,error:null});
  const range={from:new Date('2026-10-01Z'),to:new Date('2026-10-10Z')};
  expect(await getPartnerFunnel('institution',range)).toEqual(rows);
  expect(rpc).toHaveBeenCalledWith('get_tp2_partner_funnel_v2',{p_partner_id:'institution',p_from:range.from.toISOString(),p_to:range.to.toISOString()});
 });
 it('preserves all-time default and denied access',async()=>{
  rpc.mockResolvedValue({data:null,error:new Error('denied')});await expect(getPartnerFunnel()).rejects.toThrow('denied');
  expect(rpc).toHaveBeenCalledWith('get_tp2_partner_funnel_v2',{p_partner_id:null,p_from:null,p_to:null});
 });
 it('normalizes MEC unified keys for the preserved RPC',async()=>{
  rpc.mockResolvedValue({data:{entities:[],totals:{}},error:null});expect((await getMecDashboard('mec_entity',null)).entities).toEqual([]);
  expect(rpc).toHaveBeenCalledWith('get_mec_engagement_dashboard',{p_entity_id:'entity',p_days_ago:null});
 });
 it('does not invent zero rates',()=>{expect(cohortRate(0,0)).toBeNull();expect(cohortRate(7,2)).toBe(350);});
 it('propagates MEC errors',async()=>{rpc.mockResolvedValue({data:null,error:new Error('denied')});await expect(getMecDashboard()).rejects.toThrow('denied');});
 // TP-G consumers of the frozen TP-D contract.
 it('portal and B2B all-time pass an empty range, which reaches v2 as NULL/NULL',async()=>{
  rpc.mockResolvedValue({data:[],error:null});await getPartnerFunnel('inst',{});
  expect(rpc).toHaveBeenCalledWith('get_tp2_partner_funnel_v2',{p_partner_id:'inst',p_from:null,p_to:null});
 });
 it('still accepts numeric days for published callers of the transitional signature',async()=>{
  rpc.mockResolvedValue({data:[],error:null});await getPartnerFunnel('all',7);
  const args=rpc.mock.calls[0][1];expect(args.p_partner_id).toBeNull();expect(args.p_to).toBeNull();expect(typeof args.p_from).toBe('string');
 });
 it('volumes reuse the server-normalized MEC window and pass page/search/filters/order',async()=>{
  const dash={period:{from:null,to:'2026-10-20T15:00:00Z'}} as unknown as MecDashboardData;
  const range=mecRangeFromDashboard(dash);expect(range).toEqual({from:undefined,to:new Date('2026-10-20T15:00:00Z')});
  rpc.mockResolvedValue({data:{total_count:0,rows:[]},error:null});
  await getMecOpportunityVolumes({range,search:'medicina',institutionId:'inst',type:'prouni',order:'redirects',limit:25,offset:25});
  expect(rpc).toHaveBeenCalledWith('get_mec_opportunity_volumes',{p_from:null,p_to:'2026-10-20T15:00:00.000Z',p_search:'medicina',p_institution_id:'inst',p_type:'prouni',p_order:'redirects',p_limit:25,p_offset:25});
  rpc.mockResolvedValue({data:[{id:'inst',name:'UFMG'}],error:null});
  expect(await getMecVolumeInstitutions(range)).toEqual([{id:'inst',name:'UFMG'}]);
  expect(rpc).toHaveBeenLastCalledWith('get_mec_volume_institutions',{p_from:null,p_to:'2026-10-20T15:00:00.000Z'});
 });
 it('the selector value (entity_id) reaches the MEC RPC unchanged',async()=>{
  rpc.mockResolvedValue({data:{entities:[]},error:null});await getMecDashboard('11111111-1111-4111-8111-111111111111',30);
  expect(rpc).toHaveBeenCalledWith('get_mec_engagement_dashboard',{p_entity_id:'11111111-1111-4111-8111-111111111111',p_days_ago:30});
 });
});
