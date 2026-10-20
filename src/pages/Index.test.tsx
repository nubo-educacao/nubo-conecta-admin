import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import Index from "./Index";
import { useDashboardStats } from "@/hooks/useAnalyticsData";

// Sem .env: nenhum import pode criar o client real.
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: vi.fn(), from: vi.fn(), functions: { invoke: vi.fn() } } }));
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
vi.mock("@/components/analytics/TopUsersChart", () => ({ TopUsersChart: ({ dateRange }: any) => <div data-testid="users-period">{dateRange?.from?.toISOString()}</div> }));
vi.mock("@/components/action-center/ActionCenter", () => ({ ActionCenter: () => <div>Central de Ações</div> }));
vi.mock("@/components/analytics/NsmCard", () => ({ NsmCard: () => <div>NSM encaminhamentos por aluno ativo</div> }));
// Gráficos que saíram para Analytics (NUB-RD-89): se o CC voltar a montá-los, o texto aparece.
vi.mock("@/components/analytics/MatchHealthChart", () => ({ MatchHealthChart: () => <div>Saúde do Match</div> }));
vi.mock("@/components/analytics/DemographicsCharts", () => ({ DemographicsCharts: () => <div>Demografia</div> }));
vi.mock("@/components/analytics/OpportunityInterestChart", () => ({ OpportunityInterestChart: () => <div>Interesse por cliques</div> }));
vi.mock("@/components/analytics/TopCoursesChart", () => ({ TopCoursesChart: () => <div>Top cursos</div> }));
vi.mock("@/components/analytics/UserPreferencesChart", () => ({ UserPreferencesChart: () => <div>Preferências de Acesso</div> }));
vi.mock("@/components/analytics/LocationChart", () => ({ LocationChart: () => <div>Localização</div> }));
vi.mock("@/components/analytics/LocationPreferenceChart", () => ({ LocationPreferenceChart: () => <div>Preferência de localização</div> }));

function renderIndex() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <Index />
      </MemoryRouter>
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

describe('Command Center enxuto (NUB-RD-89)', () => {
  it('mantém NSM, cards, Central de Ações, Atividade e Top usuários e tira os gráficos movidos e os cards estáticos', () => {
    renderIndex();
    expect(screen.getByText('NSM encaminhamentos por aluno ativo')).toBeInTheDocument();
    expect(screen.getByText('Central de Ações')).toBeInTheDocument();
    expect(screen.getByTestId('activity-period')).toBeInTheDocument();
    expect(screen.getByTestId('users-period')).toBeInTheDocument();
    expect(screen.getByLabelText('Total de Mensagens')).toBeInTheDocument();
    expect(screen.getByLabelText('Favoritos Salvos')).toBeInTheDocument();
    for (const gone of ['Saúde do Match', 'Demografia', 'Interesse por cliques', 'Top cursos', 'Preferências de Acesso', 'Localização', 'Preferência de localização',
      'Dados em Tempo Real', 'Período de Análise', 'Conectado ao Supabase']) expect(screen.queryByText(gone)).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Analytics de Produto/ })).toHaveAttribute('href', '/analytics');
  });
  it('NSM fica no topo, antes dos cards', () => {
    renderIndex();
    const nsm = screen.getByText('NSM encaminhamentos por aluno ativo');
    expect(nsm.compareDocumentPosition(screen.getByLabelText('Total de Mensagens')) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });
  it('rodapé do Command Center sem "Cloudinha Analytics"', () => {
    renderIndex();
    expect(screen.getByText('Nubo Conecta · Command Center © 2026')).toBeInTheDocument();
    expect(screen.queryByText(/Cloudinha Analytics/)).not.toBeInTheDocument();
  });
});

describe('Command Center selected period', () => {
  it('passes today and a custom day to stats, activity and top users', () => {
    renderIndex();
    fireEvent.click(screen.getByText('Hoje'));
    const today = new Date(); today.setHours(0, 0, 0, 0);
    for (const panel of ['activity-period', 'users-period']) expect(screen.getByTestId(panel)).toHaveTextContent(today.toISOString());
    expect(vi.mocked(useDashboardStats).mock.calls.at(-1)?.[0]?.from).toEqual(today);
    fireEvent.click(screen.getByText('Data específica'));
    const custom = new Date(2026, 8, 2);
    for (const panel of ['activity-period', 'users-period']) expect(screen.getByTestId(panel)).toHaveTextContent(custom.toISOString());
    expect(vi.mocked(useDashboardStats).mock.calls.at(-1)?.[0]?.from).toEqual(custom);
  });
});
