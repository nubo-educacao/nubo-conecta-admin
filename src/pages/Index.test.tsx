import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import Index from "./Index";

vi.mock("@/hooks/useAnalyticsData", () => ({
  useDashboardStats: () => ({
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
  }),
}));

vi.mock("@/components/analytics/OpportunityTypesChart", () => ({
  OpportunityTypesChart: () => <div>Erro ao carregar dados</div>,
}));

vi.mock("@/components/analytics/DashboardHeader", () => ({ DashboardHeader: () => null }));
vi.mock("@/components/analytics/PowerUsersCard", () => ({ PowerUsersCard: () => null }));
vi.mock("@/components/analytics/TotalUsersCard", () => ({ TotalUsersCard: () => null }));
vi.mock("@/components/analytics/StatCard", () => ({ StatCard: () => null }));
vi.mock("@/components/analytics/ActivityChart", () => ({ ActivityChart: () => null }));
vi.mock("@/components/analytics/TopCoursesChart", () => ({ TopCoursesChart: () => null }));
vi.mock("@/components/analytics/FlowFunnelChart", () => ({ FlowFunnelChart: () => null }));
vi.mock("@/components/analytics/LocationPreferenceChart", () => ({ LocationPreferenceChart: () => null }));
vi.mock("@/components/analytics/TopUsersChart", () => ({ TopUsersChart: () => null }));
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
});
