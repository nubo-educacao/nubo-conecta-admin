import { render, screen, fireEvent } from '@testing-library/react';
import { TopUsersChart } from './TopUsersChart';
import { useTopUsers } from '@/hooks/useAnalyticsData';
import { downloadAnalyticsCsv } from '@/lib/analyticsCsv';

vi.mock('@/hooks/useAnalyticsData', () => ({ useTopUsers: vi.fn() }));
vi.mock('@/lib/analyticsCsv', () => ({ downloadAnalyticsCsv: vi.fn() }));
const dateRange = { from: new Date('2026-06-15T03:00:00Z'), to: new Date('2026-06-16T03:00:00Z') };

it('distinguishes empty results from source errors, including a stale cached ranking', () => {
  vi.mocked(useTopUsers).mockReturnValue({ data: [], isLoading: false } as any);
  const view = render(<TopUsersChart dateRange={dateRange} />);
  expect(screen.getByText('Nenhuma mensagem de usuário no período selecionado.')).toBeInTheDocument();
  vi.mocked(useTopUsers).mockReturnValue({ data: [{ id: 'old', name: 'Stale', messages: 99 }], error: new Error(), isLoading: false } as any);
  view.rerender(<TopUsersChart dateRange={dateRange} />);
  expect(screen.getByRole('alert')).toHaveTextContent('Não foi possível carregar');
  expect(screen.queryByText('Stale')).not.toBeInTheDocument();
});

it('uses message volume for bars and exports exactly the visible ranking and period', () => {
  const users = [
    { id: 'a', name: 'A', messages: 3, sessions: 2, favorites: 0, score: 100 },
    { id: 'b', name: 'B', messages: 2, sessions: 1, favorites: 20, score: 50 },
  ];
  vi.mocked(useTopUsers).mockReturnValue({ data: users, isLoading: false } as any);
  const { container } = render(<TopUsersChart dateRange={dateRange} />);
  expect(useTopUsers).toHaveBeenLastCalledWith(dateRange);
  expect(container.querySelector('[style*="66.666"]')?.getAttribute('style')).toContain('66.666');
  fireEvent.click(screen.getByRole('button', { name: 'Exportar ranking' }));
  expect(downloadAnalyticsCsv).toHaveBeenCalledWith(expect.any(Array), [['A', 3, 2, 0], ['B', 2, 1, 20]], 'ranking-mensagens', dateRange);
  expect(screen.queryByRole('button', { name: 'Match Realizado' })).not.toBeInTheDocument();
});
