import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen, fireEvent } from "@testing-library/react";
import Index from "./Index";
import { useDashboardStats } from "@/hooks/useAnalyticsData";

vi.mock("@/hooks/useAnalyticsData", () => ({
  useDashboardStats: vi.fn(() => ({
    data: {
      totalRegistered: 0,
      activeUsers: 0,
      activeUsersWithMessages: 0,
      catalogUsers: 0,
      powerUsers: 0,
      powerUsersList: [],
      totalMessages: 0,
      totalFavorites: 0,
    },
    isLoading: false,
  })),
}));

vi.mock("@/components/analytics/MatchHealthChart", () => ({ MatchHealthChart: () => null }));
vi.mock("@/components/analytics/DemographicsCharts", () => ({ DemographicsCharts: () => null }));

vi.mock("@/components/analytics/OpportunityTypesChart", () => ({
  OpportunityTypesChart: () => <div>Erro ao carregar dados</div>,
}));

vi.mock("@/components/analytics/DashboardHeader", () => ({ DashboardHeader: ({ onRangeChange, onCustomDateChange }: any) => <>
  <button onClick={() => onRangeChange('today')}>Hoje</button>
  <button onClick={() => { onCustomDateChange(new Date(2026, 8, 2)); onRangeChange('custom'); }}>Data específica</button>
</> }));
vi.mock("@/components/analytics/PowerUsersCard", () => ({ PowerUsersCard: () => null }));
vi.mock("@/components/analytics/TotalUsersCard", () => ({ TotalUsersCard: () => null }));
vi.mock("@/components/analytics/StatCard", () => ({ StatCard: ({ title, value, tooltip, change }: any) => <div aria-label={title}>{value}<span>{tooltip}</span>{change !== undefined && <span>{change}%</span>}</div> }));
vi.mock("@/components/analytics/ActivityChart", () => ({ ActivityChart: ({ dateRange }: any) => <div data-testid="activity-period">{dateRange?.from?.toISOString()}</div> }));
vi.mock("@/components/analytics/TopCoursesChart", () => ({ TopCoursesChart: () => null }));
vi.mock("@/components/analytics/FlowFunnelChart", () => ({ FlowFunnelChart: () => null }));
vi.mock("@/components/analytics/LocationPreferenceChart", () => ({ LocationPreferenceChart: () => null }));
vi.mock("@/components/analytics/TopUsersChart", () => ({ TopUsersChart: ({ dateRange }: any) => <div data-testid="users-period">{dateRange?.from?.toISOString()}</div> }));
vi.mock("@/components/analytics/LocationChart", () => ({ LocationChart: () => null }));
vi.mock("@/components/action-center/ActionCenter", () => ({ ActionCenter: () => null }));

function renderIndex() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <Index />
    </QueryClientProvider>,
  );
}

describe("Command Center", () => {
  it("não renderiza o card órfão de Oportunidades Buscadas", () => {
    renderIndex();

    expect(screen.queryByText("Erro ao carregar dados")).not.toBeInTheDocument();
    expect(screen.queryByText("Oportunidades Buscadas")).not.toBeInTheDocument();
  });
  it("explains the user-only metric and keeps a true zero distinct from missing data", () => {
    renderIndex();
    expect(screen.getByLabelText('Total de Mensagens')).toHaveTextContent('0');
    expect(screen.getByLabelText('Total de Mensagens')).toHaveTextContent('Exclui mensagens do sistema e do assistente');
  });
  it("does not show stale successful metrics after a request error", () => {
    vi.mocked(useDashboardStats).mockReturnValueOnce({
      data: { totalMessages: 99, messagesChange: 100 }, isLoading: false, isError: true,
    } as any);
    renderIndex();
    expect(screen.getByLabelText('Total de Mensagens')).toHaveTextContent('Indisponível');
    expect(screen.getByLabelText('Total de Mensagens')).not.toHaveTextContent('99');
    expect(screen.getByLabelText('Total de Mensagens')).not.toHaveTextContent('100%');
    for (const title of ['Usuários Cadastrados', 'Power Users', 'Favoritos Salvos']) expect(screen.getByLabelText(title)).toHaveTextContent('Indisponível');
  });
});

vi.mock('@/components/analytics/MatchHealthChart', () => ({ MatchHealthChart: () => <div>Saúde do Match</div> }));
vi.mock('@/components/analytics/DemographicsCharts', () => ({ DemographicsCharts: () => <div>Demografia preservada</div> }));
vi.mock('@/components/analytics/UserPreferencesChart', () => ({ UserPreferencesChart: () => <div>Preferências de Acesso</div> }));
vi.mock('@/components/analytics/OpportunityInterestChart', () => ({ OpportunityInterestChart: ({ dateRange }: any) => <div data-testid="interest-period">{dateRange?.from?.toISOString()}</div> }));

describe('Command Center selected period', () => {
  it('passes today and a custom day to stats and opportunity interest, preserving existing panels', () => {
    renderIndex();
    expect(screen.getByText('Saúde do Match')).toBeInTheDocument();
    expect(screen.getByText('Demografia preservada')).toBeInTheDocument();
    expect(screen.getByText('Preferências de Acesso')).toBeInTheDocument();
    fireEvent.click(screen.getByText('Hoje'));
    const today = new Date(); today.setHours(0, 0, 0, 0);
    for (const panel of ['interest-period', 'activity-period', 'users-period']) expect(screen.getByTestId(panel)).toHaveTextContent(today.toISOString());
    expect(vi.mocked(useDashboardStats).mock.calls.at(-1)?.[0]?.from).toEqual(today);
    fireEvent.click(screen.getByText('Data específica'));
    const custom = new Date(2026, 8, 2);
    for (const panel of ['interest-period', 'activity-period', 'users-period']) expect(screen.getByTestId(panel)).toHaveTextContent(custom.toISOString());
    expect(vi.mocked(useDashboardStats).mock.calls.at(-1)?.[0]?.from).toEqual(custom);
  });
});
