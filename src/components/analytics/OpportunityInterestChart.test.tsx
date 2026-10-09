import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { OpportunityInterestChart } from './OpportunityInterestChart';
import { fetchOpportunityInterest } from '@/services/opportunityInterestService';
vi.mock('@/services/opportunityInterestService', () => ({ fetchOpportunityInterest: vi.fn() }));
beforeEach(() => { vi.mocked(fetchOpportunityInterest).mockReset(); });
function show() {
  return render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}><OpportunityInterestChart dateRange={{ from: new Date('2026-10-01'), to: new Date('2026-10-09') }} /></QueryClientProvider>);
}
describe('opportunity interest chart', () => {
  it('shows real opportunity titles, providers and weighted clicks', async () => {
    vi.mocked(fetchOpportunityInterest).mockResolvedValue([{ opportunity_id: 'partner_1', title: 'Bolsa Insper', provider: 'Insper', clicks: 7 }]);
    show();
    expect(await screen.findByText('Bolsa Insper')).toBeInTheDocument();
    expect(screen.getByText('Insper')).toBeInTheDocument();
    expect(screen.getByText('7 cliques')).toBeInTheDocument();
    expect(fetchOpportunityInterest).toHaveBeenCalledWith({ from: new Date('2026-10-01'), to: new Date('2026-10-09') });
  });
  it('shows a truthful empty state', async () => {
    vi.mocked(fetchOpportunityInterest).mockResolvedValue([]); show();
    expect(await screen.findByText('Nenhum clique em oportunidades neste período.')).toBeInTheDocument();
  });
  it('distinguishes unavailable data from an empty ranking', async () => {
    vi.mocked(fetchOpportunityInterest).mockImplementation(async () => { throw { message: 'unavailable', code: '42501' }; }); show();
    expect(await screen.findByText('Não foi possível carregar o interesse por oportunidades.')).toBeInTheDocument();
    expect(screen.queryByText('Nenhum clique em oportunidades neste período.')).not.toBeInTheDocument();
  });
});
