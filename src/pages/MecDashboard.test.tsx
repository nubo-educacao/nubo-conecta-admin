import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
const { state } = vi.hoisted(() => ({ state: { current: {} as any } }));
vi.mock("@tanstack/react-query", () => ({ useQuery: () => state.current }));
vi.mock("@/services/mecDashboardService", () => ({
  getMecDashboard: vi.fn(),
  cohortRate: (n: number, d: number) => d > 0 ? n / d * 100 : null,
}));
import MecDashboard from "@/pages/MecDashboard";
afterEach(cleanup);
const data = {
  totals: { card_view: 2, card_click: 8, redirect: 12, distinct_users: 1, distinct_identities: 2 },
  cohort: { viewers: 2, clickers: 1, redirectors: 0 },
  coverage: { first_observed_at: null, first_view_at: null, legacy_events: 7 },
  period: { from: null, to: "2026-10-09T19:00:00Z" },
  entities: [{ entity_id: "fixture-entity", card_view: 2, card_click: 8, redirect: 12, distinct_users: 1 }],
};
describe("MEC dashboard behavior", () => {
  it("shows historical nonmonotonic volumes without converting redirects into completed applications", () => {
    state.current = { data, isLoading: false, isError: false };
    render(<MecDashboard />);
    expect(screen.getByText(/não confirma candidatura concluída/)).toBeInTheDocument();
    expect(screen.getByText("Funil MEC — coorte sequencial")).toBeInTheDocument();
    expect(screen.getByText("50.0%")).toBeInTheDocument();
    expect(screen.getAllByText("12").length).toBe(2);
    expect(screen.getByText(/par identidade \+ oportunidade/)).toBeInTheDocument();
  });
  it("shows an empty state and no rate with no observed cohort", () => {
    state.current = { data: { ...data, entities: [], cohort: { viewers: 0, clickers: 0, redirectors: 0 } }, isError: false };
    render(<MecDashboard />);
    expect(screen.getByText("Nenhum evento MEC encontrado no período.")).toBeInTheDocument();
    expect(screen.getAllByText("Sem denominador elegível")).toHaveLength(2);
  });
  it("shows denied/network failure as an error, with retry, never as an empty dataset", () => {
    state.current = { data, isError: true, refetch: vi.fn() };
    render(<MecDashboard />);
    expect(screen.getByRole("alert")).toHaveTextContent("Não foi possível carregar");
    expect(screen.getByRole("button", { name: "Tentar novamente" })).toBeInTheDocument();
    expect(screen.queryByText("Funil MEC — coorte sequencial")).not.toBeInTheDocument();
  });
  it("shows loading while fetching the selected period", () => {
    state.current = { isLoading: true, isError: false };
    render(<MecDashboard />);
    expect(screen.getByRole("status")).toHaveTextContent("Carregando métricas MEC");
  });
});

