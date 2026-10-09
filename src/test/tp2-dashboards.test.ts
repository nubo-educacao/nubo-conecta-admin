import { beforeEach, describe, expect, it, vi } from 'vitest';
const { rpc } = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('@/integrations/supabase/client', () => ({ supabase: { rpc } }));
import { getPartnerFunnel } from '@/services/passportDashboardService';
import { getMecDashboard, cohortRate } from '@/services/mecDashboardService';
beforeEach(() => rpc.mockReset());
describe('TP-2 contracts', () => {
  it('requests B2B by institution and period, distinguishing events and people', async () => {
    const rows = [{ total_card_clicks: 9, total_unique_clicks: 2 }];
    rpc.mockResolvedValue({ data: rows, error: null });
    expect(await getPartnerFunnel('institution', 7)).toEqual(rows);
    expect(rpc).toHaveBeenCalledWith('get_tp2_partner_funnel', { p_partner_id: 'institution', p_days_ago: 7 });
  });
  it('preserves the portal all-time default and propagates denied access', async () => {
    rpc.mockResolvedValue({ data: null, error: new Error('denied') });
    await expect(getPartnerFunnel()).rejects.toThrow('denied');
    expect(rpc).toHaveBeenCalledWith('get_tp2_partner_funnel', { p_partner_id: null, p_days_ago: null });
  });
  it('preserves a real empty MEC response with entity and period', async () => {
    rpc.mockResolvedValue({ data: { entities: [], totals: {} }, error: null });
    expect((await getMecDashboard('mec-id', 30)).entities).toEqual([]);
    expect(rpc).toHaveBeenCalledWith('get_mec_engagement_dashboard', { p_entity_id: 'mec-id', p_days_ago: 30 });
  });
  it('shows no rate without an eligible denominator', () => {
    expect(cohortRate(0, 0)).toBeNull();
    expect(cohortRate(1, 4)).toBe(25);
  });
  it('propagates MEC errors instead of fake zeros', async () => {
    rpc.mockResolvedValue({ data: null, error: new Error('denied') });
    await expect(getMecDashboard()).rejects.toThrow('denied');
  });
});
