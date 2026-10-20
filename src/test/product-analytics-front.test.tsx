import { beforeEach,describe,it,expect,vi } from 'vitest';
import { render,screen } from '@testing-library/react';
const {rpc}=vi.hoisted(()=>({rpc:vi.fn()}));
vi.mock('@/integrations/supabase/client',()=>({supabase:{rpc}}));
import { fetchGlobalFunnel,fetchNsm,fetchL1,fetchL2,productAnalyticsKeys } from '@/services/productAnalyticsService';
import { getMecOpportunityVolumes,toMecEntityId } from '@/services/mecDashboardService';
import { FunnelChart } from '@/components/analytics/FunnelChart';
beforeEach(()=>rpc.mockReset());
describe('TP-D consumers',()=>{
 it('sends period and first touch and makes distinct cache keys',async()=>{
  rpc.mockResolvedValue({data:{domains:{}},error:null});
  const range={from:new Date('2026-10-01Z'),to:new Date('2026-10-10Z')};const attribution={campaignId:'campaign'};
  await fetchGlobalFunnel(range,attribution);
  expect(rpc).toHaveBeenCalledWith('get_product_global_funnel',{p_from:range.from.toISOString(),p_to:range.to.toISOString(),p_filter_campaign_id:'campaign',p_filter_channel_id:null,p_filter_unattributed:null});
  expect(productAnalyticsKeys.global(range,attribution)).not.toEqual(productAnalyticsKeys.global(undefined,attribution));
  expect(productAnalyticsKeys.global(range,attribution)).not.toEqual(productAnalyticsKeys.global(range,{}));
 });
 it('propagates errors from every new product contract',async()=>{
  rpc.mockResolvedValue({data:null,error:new Error('denied')});
  for(const fetch of [()=>fetchGlobalFunnel(),()=>fetchNsm(),()=>fetchL1(),()=>fetchL2()])await expect(fetch()).rejects.toThrow('denied');
 });
 it('maps MEC keys and preserves empty server pages',async()=>{
  rpc.mockResolvedValue({data:{rows:[],total_count:12},error:null});
  expect((await getMecOpportunityVolumes({offset:25})).total_count).toBe(12);
  expect(toMecEntityId('mec_abc')).toBe('abc');expect(toMecEntityId('abc')).toBe('abc');
 });
 it('retains domain order and values > previous with explicit observed ratio',()=>{
  render(<FunnelChart mode="observed_volumes" unitLabel="eventos" steps={[{key:'view',label:'Views',value:5},{key:'click',label:'Clicks',value:2},{key:'terminal',label:'Terminal',value:7}]} />);
  expect(screen.getByRole('img')).toHaveAccessibleName(/volumes observados/i);
  expect(screen.getAllByTestId('funnel-step').map(x=>x.getAttribute('data-step'))).toEqual(['view','click','terminal']);
  expect(screen.getByText(/350/)).toBeInTheDocument();expect(screen.getByText('7')).toBeInTheDocument();
 });
 it('distinguishes null from measured zero and does not stack people',()=>{
  render(<FunnelChart mode="observed_volumes" unitLabel="pessoas" steps={[{key:'a',label:'Ausente',value:null,notInstrumented:true},{key:'z',label:'Medido',value:0}]} />);
  expect(screen.getByText('Não instrumentado')).toBeInTheDocument();expect(screen.getByText('0')).toBeInTheDocument();
 });
});
