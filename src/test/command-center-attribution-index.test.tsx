// Command Center (Index): o recorte de campanha/divulgador mora na URL (mesmas
// chaves de Estudantes/Inscrições) e chega a todos os painéis de pessoas.
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router-dom";
import Index from "@/pages/Index";
import { useDashboardStats } from "@/hooks/useAnalyticsData";

const CAMPAIGN = "11111111-1111-1111-1111-111111111111";
const CHANNEL = "22222222-2222-2222-2222-222222222222";

// Sem .env: nenhum import pode criar o client real.
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: vi.fn(), from: vi.fn(), functions: { invoke: vi.fn() } } }));
vi.mock("@/hooks/useAnalyticsData", () => ({
  useDashboardStats: vi.fn(() => ({
    data: { totalRegistered: 0, activeUsers: 0, activeUsersWithMessages: 0, catalogUsers: 0, powerUsers: 0,
      powerUsersList: [], totalMessages: 0, totalFavorites: 0 },
    isLoading: false,
  })),
}));

// Cada painel expõe o recorte que recebeu.
const { probe } = vi.hoisted(() => ({
  probe: (name: string) => ({ attribution }: any) => <div data-testid={name}>{JSON.stringify(attribution ?? null)}</div>,
}));
// Desde NUB-RD-89 (composição do PO, 20/10) o CC tem Atividade, Top usuários e o funil global;
// a NSM e os demais painéis estão em Analytics.
const PANELS = ["ActivityChart", "TopUsersChart", "GlobalFunnelSection"] as const;
vi.mock("@/components/analytics/ActivityChart", () => ({ ActivityChart: probe("ActivityChart") }));
vi.mock("@/components/analytics/TopUsersChart", () => ({ TopUsersChart: probe("TopUsersChart") }));
vi.mock("@/components/analytics/GlobalFunnelSection", () => ({ GlobalFunnelSection: probe("GlobalFunnelSection") }));
vi.mock("@/components/analytics/PowerUsersCard", () => ({ PowerUsersCard: () => null }));
vi.mock("@/components/analytics/TotalUsersCard", () => ({ TotalUsersCard: () => null }));
vi.mock("@/components/action-center/ActionCenter", () => ({ ActionCenter: () => <div data-testid="ActionCenter" /> }));
vi.mock("@/components/analytics/DashboardHeader", () => ({
  DashboardHeader: ({ attribution, onAttributionChange }: any) => <>
    <div data-testid="header-attribution">{JSON.stringify(attribution ?? null)}</div>
    <button onClick={() => onAttributionChange({ campaignId: CAMPAIGN, channelId: CHANNEL })}>Escolher campanha</button>
    <button onClick={() => onAttributionChange({ unattributed: true })}>Sem atribuição</button>
    <button onClick={() => onAttributionChange({})}>Limpar</button>
  </>,
}));

function Search() {
  return <div data-testid="search">{useLocation().search}</div>;
}

function renderAt(url: string) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[url]}>
        <Index />
        <Search />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

const panelValues = () => PANELS.map((p) => screen.getByTestId(p).textContent);

beforeEach(() => vi.mocked(useDashboardStats).mockClear());

describe("Command Center — recorte por campanha/divulgador", () => {
  it("sem filtro: nada muda nas chamadas (useDashboardStats só com o período)", () => {
    renderAt("/");
    expect(vi.mocked(useDashboardStats).mock.calls.at(-1)).toHaveLength(1);
    expect(screen.getByTestId("header-attribution")).toHaveTextContent("{}");
    expect(screen.queryByText(/Recorte por campanha\/divulgador/)).not.toBeInTheDocument();
  });

  it("lê o recorte da URL e o passa ao header, aos stats, ao funil global e aos painéis de pessoas", () => {
    renderAt(`/?campaignId=${CAMPAIGN}`);
    const expected = JSON.stringify({ campaignId: CAMPAIGN });
    expect(screen.getByTestId("header-attribution")).toHaveTextContent(expected);
    expect(vi.mocked(useDashboardStats).mock.calls.at(-1)?.[1]).toEqual({ campaignId: CAMPAIGN });
    expect(panelValues()).toEqual(PANELS.map(() => expected));
    expect(screen.getByText(/Recorte por campanha\/divulgador/)).toBeInTheDocument();
  });

  it("escrever o recorte atualiza a URL (mesmas chaves de Estudantes) e os painéis", () => {
    renderAt("/?foo=1");
    fireEvent.click(screen.getByText("Escolher campanha"));
    const search = new URLSearchParams(screen.getByTestId("search").textContent ?? "");
    expect(search.get("campaignId")).toBe(CAMPAIGN);
    expect(search.get("channelId")).toBe(CHANNEL);
    expect(search.get("foo")).toBe("1");
    expect(screen.getByTestId("TopUsersChart")).toHaveTextContent(JSON.stringify({ campaignId: CAMPAIGN, channelId: CHANNEL }));

    fireEvent.click(screen.getByText("Sem atribuição"));
    const next = new URLSearchParams(screen.getByTestId("search").textContent ?? "");
    expect(next.get("unattributed")).toBe("true");
    expect(next.get("campaignId")).toBeNull();
    expect(next.get("channelId")).toBeNull();

    fireEvent.click(screen.getByText("Limpar"));
    expect(screen.getByTestId("search")).toHaveTextContent("?foo=1");
    expect(vi.mocked(useDashboardStats).mock.calls.at(-1)).toHaveLength(1);
  });
});
