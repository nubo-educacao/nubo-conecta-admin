import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { getPartnerFunnel, getStudentApplicationsOverTime } from "@/services/passportDashboardService";

vi.mock("@/components/ui/select", () => import("@/test/selectShim"));
vi.mock("@/services/applicationsService", () => ({
  getPartnersList: vi.fn(async () => []),
  getInstitutionsList: vi.fn(async () => [{ id: "inst-estudar", name: "Estudar" }]),
}));
vi.mock("@/services/passportDashboardService", () => ({
  getPartnerFunnel: vi.fn(),
  getPartnerApplicationBuckets: vi.fn(async () => []),
  getStudentApplicationsOverTime: vi.fn(async () => []),
  getAdminFunnelUsers: vi.fn(async () => []),
}));
import PassportDashboard from "@/pages/PassportDashboard";

// Fixture shaped after the BDD: historical programs only active in March/April, BIP only legacy v0 redirects.
const rows = [
  { partner_id: "inst-estudar", partner_name: "Estudar", total_unique_clicks: 120, total_applications_started: 340, total_applications_completed: 326, total_card_clicks: 410, legacy_external_redirects: 0, last_activity_at: "2026-04-28T18:00:00Z" },
  { partner_id: "inst-ponte", partner_name: "Ponte", total_unique_clicks: 30, total_applications_started: 99, total_applications_completed: 95, total_card_clicks: 44, legacy_external_redirects: 0, last_activity_at: "2026-03-31T12:00:00Z" },
  { partner_id: "inst-bip", partner_name: "BIP", total_unique_clicks: 0, total_applications_started: 0, total_applications_completed: 0, total_card_clicks: 0, legacy_external_redirects: 369, last_activity_at: null },
];

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={client}><PassportDashboard /></QueryClientProvider>);
}

beforeEach(() => {
  vi.mocked(getPartnerFunnel).mockReset().mockResolvedValue(rows);
  vi.mocked(getStudentApplicationsOverTime).mockClear();
});
afterEach(cleanup);

describe("B2B partner funnel card", () => {
  it("defaults to all-time (NULL/NULL) with its own period, separate from the time series filter", async () => {
    renderPage();
    await screen.findByText("Funil por Parceiro Institucional");
    expect(getPartnerFunnel).toHaveBeenCalledWith("all", {});
    expect(getStudentApplicationsOverTime).toHaveBeenCalledWith("all", 30);
    expect(screen.getByLabelText("Período do funil")).toHaveValue("all");
    expect(screen.getByText("Período: Todo o período")).toBeInTheDocument();
  });

  it("changing the funnel period does not touch the time series period", async () => {
    renderPage();
    await screen.findByText("Funil por Parceiro Institucional");
    fireEvent.change(screen.getByLabelText("Período do funil"), { target: { value: "7d" } });
    await waitFor(() => expect(getPartnerFunnel).toHaveBeenLastCalledWith("all", { from: expect.any(Date) }));
    expect(getStudentApplicationsOverTime).not.toHaveBeenCalledWith("all", 7);
    expect(screen.getByText(/^Período: .* até agora/)).toBeInTheDocument();
  });

  it("custom range sends whole BRT days with an exclusive end and shows it", async () => {
    renderPage();
    await screen.findByText("Funil por Parceiro Institucional");
    fireEvent.change(screen.getByLabelText("Período do funil"), { target: { value: "custom" } });
    fireEvent.change(screen.getByLabelText("Início do período do funil"), { target: { value: "2026-03-01" } });
    fireEvent.change(screen.getByLabelText("Fim do período do funil"), { target: { value: "2026-04-30" } });
    await waitFor(() => expect(getPartnerFunnel).toHaveBeenLastCalledWith("all", {
      from: new Date("2026-03-01T03:00:00Z"), to: new Date("2026-05-01T03:00:00Z"),
    }));
    expect(screen.getByText(/01\/03\/2026 00:00 até 01\/05\/2026 00:00/)).toBeInTheDocument();
  });

  it("draws click → started → completed as observed user volumes, without an invented view step", async () => {
    renderPage();
    const chart = await screen.findByRole("img", { name: /Funil de volumes observados/ });
    const steps = within(chart).getAllByTestId("funnel-step").map((s) => s.getAttribute("data-step"));
    expect(steps).toEqual(["card_click", "applications_started", "applications_completed"]);
    // "todas": sums of per-institution counts, labelled as such; terminal > click keeps its real value.
    expect(chart).toHaveAccessibleName(/Clicou no card: 150; Candidatura iniciada: 439; Candidatura concluída: 421/);
    expect(screen.getByText(/Razão de volumes observados: 292,7%/)).toBeInTheDocument();
    expect(screen.getByText(/soma das contagens por instituição/)).toBeInTheDocument();
    expect(screen.getByText(/não são pessoas únicas/)).toBeInTheDocument();
    // Card-click events stay in the detail, in their own unit.
    expect(screen.getByText(/Cliques no card \(eventos\): 454/)).toBeInTheDocument();
  });

  it("keeps the table as detail with legacy v0 redirects apart from completed and last activity", async () => {
    renderPage();
    const table = await screen.findByRole("table", { name: "Detalhe do funil por parceiro" });
    expect(within(table).getByRole("columnheader", { name: /Redirects legados v0/ })).toBeInTheDocument();
    const bip = within(table).getByRole("row", { name: /BIP/ });
    expect(within(bip).getAllByRole("cell").map((c) => c.textContent)).toEqual(["BIP", "0", "0", "0", "0", "—", "369", "sem atividade"]);
    const ponte = within(table).getByRole("row", { name: /Ponte/ });
    expect(ponte).toHaveTextContent("95");
    expect(ponte).toHaveTextContent("31/03/2026");
    expect(screen.getByText(/redirect externo da v0, não somado a concluídas/)).toBeInTheDocument();
  });

  it("a single institution uses plain distinct users and its own row", async () => {
    vi.mocked(getPartnerFunnel).mockResolvedValue([rows[1]]);
    renderPage();
    await screen.findByText("Funil por Parceiro Institucional");
    fireEvent.change(screen.getByLabelText("Instituição do funil"), { target: { value: "inst-estudar" } });
    await waitFor(() => expect(getPartnerFunnel).toHaveBeenLastCalledWith("inst-estudar", {}));
    expect(await screen.findByRole("img", { name: /usuários distintos: Clicou no card: 30/ })).toBeInTheDocument();
    expect(screen.queryByText(/soma das contagens por instituição/)).not.toBeInTheDocument();
  });

  it("shows denied access as an error, not as zeros", async () => {
    vi.mocked(getPartnerFunnel).mockRejectedValue(new Error("Access denied"));
    renderPage();
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível carregar o funil");
    expect(screen.queryByRole("img", { name: /Funil de volumes/ })).not.toBeInTheDocument();
  });
});
