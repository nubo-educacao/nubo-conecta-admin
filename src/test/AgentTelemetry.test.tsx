import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";
import AgentTelemetry from "@/pages/AgentTelemetry";

vi.mock("@/hooks/useAgentTelemetry", () => ({
  useTelemetryKPIs: () => ({
    data: { avgLatencyMs: 1200, turnsLast24h: 100, totalTokens: 50000, totalToolCalls: 200 },
    isLoading: false,
    isRefetching: false,
    refetch: vi.fn(),
  }),
  useLatencyByHour: () => ({ data: [], isLoading: false, isRefetching: false, refetch: vi.fn() }),
  useTokensByDay: () => ({ data: [], isLoading: false, isRefetching: false, refetch: vi.fn() }),
  useTurnsList: () => ({ data: [], isLoading: false, isRefetching: false, refetch: vi.fn() }),
  useToolStats: () => ({ data: [], isLoading: false, isRefetching: false, refetch: vi.fn() }),
}));

vi.mock("@/hooks/useAnalyticsData", () => ({
  useErrorLogs: () => ({
    data: [],
    isLoading: false,
    error: null,
    isRefetching: false,
    refetch: vi.fn(),
  }),
}));

function renderPage() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <AgentTelemetry />
      </MemoryRouter>
    </QueryClientProvider>
  );
}

describe("AgentTelemetry", () => {
  it("renderiza título e KPI cards", () => {
    renderPage();

    expect(screen.getByText("Telemetria Multi-Agente")).toBeInTheDocument();
    // "Latência Média" aparece no KPI card e no header da tabela de tools
    expect(screen.getAllByText("Latência Média").length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText("Turnos (24h)")).toBeInTheDocument();
    expect(screen.getByText("Tokens Usados")).toBeInTheDocument();
    expect(screen.getByText("Tools Chamadas")).toBeInTheDocument();
  });

  it("renderiza as duas tabs", () => {
    renderPage();

    expect(screen.getByText(/Métricas de Turnos/)).toBeInTheDocument();
    expect(screen.getByText(/Erros/)).toBeInTheDocument();
  });

  it("exibe KPI de latência formatado corretamente", () => {
    renderPage();

    // 1200ms → "1.2s"
    expect(screen.getByText("1.2s")).toBeInTheDocument();
  });
});
