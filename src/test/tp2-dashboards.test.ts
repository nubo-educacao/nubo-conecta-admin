import {beforeEach,describe,it,expect,vi} from 'vitest';
const {rpc}=vi.hoisted(()=>({rpc:vi.fn()}));vi.mock('@/integrations/supabase/client',()=>({supabase:{rpc}}));
import {getPartnerFunnel} from '@/services/passportDashboardService';
import {getMecDashboard,cohortRate} from '@/services/mecDashboardService';
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
});
