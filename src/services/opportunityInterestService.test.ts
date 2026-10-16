import { describe, it, expect, vi, beforeEach } from 'vitest';
import { fetchOpportunityInterest } from './opportunityInterestService';
import { supabase } from '@/integrations/supabase/client';
vi.mock('@/integrations/supabase/client', () => ({ supabase: { rpc: vi.fn() } }));
beforeEach(() => { vi.mocked(supabase.rpc).mockReset(); });
describe('opportunity interest read contract', () => {
  it('passes the selected period to the aggregate RPC', async () => {
    const rows = [{ opportunity_id: 'partner_1', title: 'Bolsa real', provider: 'Instituto', clicks: 9 }];
    vi.mocked(supabase.rpc).mockResolvedValue({ data: rows, error: null } as never);
    const range = { from: new Date('2026-10-01T00:00:00Z'), to: new Date('2026-10-09T00:00:00Z') };
    expect(await fetchOpportunityInterest(range)).toEqual(rows);
    expect(supabase.rpc).toHaveBeenCalledWith('get_command_center_opportunity_interest', {
      p_from: range.from.toISOString(), p_to: range.to.toISOString(), p_limit: 10,
    });
  });
  it('preserves authorization/network errors instead of fabricating zero clicks', async () => {
    vi.mocked(supabase.rpc).mockResolvedValue({ data: null, error: { code: '42501' } } as never);
    await expect(fetchOpportunityInterest()).rejects.toMatchObject({ code: '42501' });
  });
  it('returns an empty ranking when the period has no events', async () => {
    vi.mocked(supabase.rpc).mockResolvedValue({ data: [], error: null } as never);
    expect(await fetchOpportunityInterest()).toEqual([]);
  });
});
