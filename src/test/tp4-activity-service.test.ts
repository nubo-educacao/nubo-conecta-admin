import { beforeEach, describe, expect, it, vi } from 'vitest';
import { getActivityMatches, getActivityClicks, getActivityApplications } from '@/services/studentActivityService';
const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({ supabase: mocks }));
beforeEach(() => vi.resetAllMocks());

describe('TP4 activity read contracts', () => {
  it('consumes TP6 paginated matches including details and total', async () => {
    const match = { unified_opportunity_id:'course_1', title:'Curso', provider_name:'IES', match_score:80, match_details:{reason:'teste'} };
    mocks.rpc.mockResolvedValue({ data:{matches:[match],count:25}, error:null });
    expect(await getActivityMatches('student-a',1)).toEqual({data:[match],count:25});
    expect(mocks.rpc).toHaveBeenCalledWith('get_student_matches_admin_page', {p_profile_id:'student-a',p_page:1,p_page_size:20});
  });
  it('reuses clicks with the student and zero-based page', async () => {
    mocks.rpc.mockResolvedValue({data:{data:[],count:0},error:null});
    expect(await getActivityClicks('student-b',2)).toEqual({data:[],count:0});
    expect(mocks.rpc).toHaveBeenCalledWith('get_student_clicks_admin', {p_user_id:'student-b',p_page:2,p_page_size:20});
  });
  it('filters applications on the server before ordered range/count, preserving first-touch arguments', async () => {
    const builder:any = {};
    for (const method of ['select','eq','order','range']) builder[method] = vi.fn(() => builder);
    builder.then = (resolve:any) => Promise.resolve({data:[{id:'application',user_id:'student-a'}],count:21,error:null}).then(resolve);
    mocks.rpc.mockReturnValue(builder);
    const result = await getActivityApplications('student-a',1,{campaignId:'campaign',channelId:'channel'});
    expect(mocks.rpc).toHaveBeenCalledWith('get_student_applications_with_details',
      {p_filter_campaign_id:'campaign',p_filter_channel_id:'channel',p_filter_unattributed:null}, {count:'exact'});
    expect(builder.eq).toHaveBeenCalledWith('user_id','student-a');
    expect(builder.order.mock.calls).toEqual([['created_at',{ascending:false}],['id',{ascending:true}]]);
    expect(builder.range).toHaveBeenCalledWith(20,39);
    expect(result.count).toBe(21);
  });
  it('propagates collection failures, including missing totals, instead of presenting empty activity', async () => {
    mocks.rpc.mockResolvedValueOnce({data:null,error:{message:'denied'}});
    await expect(getActivityClicks('student-a',0)).rejects.toMatchObject({message:'denied'});
    mocks.rpc.mockResolvedValueOnce({data:{matches:[]},error:null});
    await expect(getActivityMatches('student-a',0)).rejects.toThrow();
  });
  it('rejects invalid student/page without querying', async () => {
    await expect(getActivityMatches('',0)).rejects.toThrow();
    await expect(getActivityClicks('student',-1)).rejects.toThrow();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
