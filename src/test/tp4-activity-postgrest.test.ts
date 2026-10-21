// @vitest-environment node
import { beforeEach, expect, it, vi } from 'vitest';
import { getActivityApplications } from '@/services/studentActivityService';
const mocks = vi.hoisted(() => ({ fetch:vi.fn() }));
vi.mock('@/integrations/supabase/client', async () => {
  const { createClient } = await import('@supabase/supabase-js');
  return {supabase:createClient('https://activity.example.invalid','synthetic-test-key',{
    auth:{persistSession:false,autoRefreshToken:false},global:{fetch:mocks.fetch},
  })};
});
beforeEach(() => vi.resetAllMocks());
it('uses the real SDK to send student/order/range/count to the table RPC and reads the filtered total', async () => {
  mocks.fetch.mockResolvedValue(new Response(JSON.stringify([{id:'app',user_id:'student-a'}]),{
    status:206,headers:{'content-type':'application/json','content-range':'20-20/21'},
  }));
  expect(await getActivityApplications('student-a',1)).toMatchObject({count:21,data:[{id:'app'}]});
  const [input,init]=mocks.fetch.mock.calls[0];
  const url=new URL(input);
  expect(url.pathname).toBe('/rest/v1/rpc/get_student_applications_with_details');
  expect(url.searchParams.get('user_id')).toBe('eq.student-a');
  expect(url.searchParams.get('order')).toBe('created_at.desc,id.asc');
  expect(url.searchParams.get('offset')).toBe('20');
  expect(url.searchParams.get('limit')).toBe('20');
  expect(url.searchParams.get('select')).not.toContain('phone');
  expect(new Headers(init.headers).get('prefer')).toContain('count=exact');
  expect(JSON.parse(init.body)).toEqual({});
});
it('keeps an exact total on an empty final page, and does not reuse the previous student', async () => {
  mocks.fetch.mockResolvedValue(new Response('[]',{status:200,headers:{'content-type':'application/json','content-range':'*/21'}}));
  expect(await getActivityApplications('student-b',2)).toEqual({data:[],count:21});
  expect(new URL(mocks.fetch.mock.calls[0][0]).searchParams.get('user_id')).toBe('eq.student-b');
});
it('rejects the actual SDK permission response as an error, not an empty collection', async () => {
  mocks.fetch.mockResolvedValue(new Response(JSON.stringify({code:'42501',message:'denied'}),{
    status:403,headers:{'content-type':'application/json'},
  }));
  await expect(getActivityApplications('student',0)).rejects.toMatchObject({code:'42501'});
});
