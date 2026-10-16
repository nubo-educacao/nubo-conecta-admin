import { fetchTopUsers, fetchActivityData } from './analytics-queries';
import { supabase } from '@/integrations/supabase/client';

vi.mock('@/integrations/supabase/client', () => ({
  supabase: { functions: { invoke: vi.fn(async () => ({ data: [], error: null })) } },
}));
it('forwards the global period to rankings and activity instead of silently using seven days', async () => {
  const dateRange = { from: new Date('2026-06-15T03:00:00Z'), to: new Date('2026-06-16T03:00:00Z') };
  await fetchTopUsers(dateRange);
  expect(supabase.functions.invoke).toHaveBeenLastCalledWith('analytics-rankings', { body: { type: 'users', dateRange } });
  await fetchActivityData(dateRange);
  expect(supabase.functions.invoke).toHaveBeenLastCalledWith('analytics-activity', { body: {
    mode: 'week', dateRange, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  } });
});
