// NUB-RD-89a/b/c — página Analytics de Produto.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router-dom";
import { l1Fixture, l2Fixture } from "@/test/productAnalyticsFixtures";

const CAMPAIGN = "11111111-1111-1111-1111-111111111111";

const { rpc, probe } = vi.hoisted(() => ({
  rpc: vi.fn(),
  // Cada gráfico expõe exatamente as props que recebeu.
  probe: (name: string) => (props: Record<string, unknown>) => (
    <div data-testid={name}>{JSON.stringify(props)}</div>
  ),
}));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc } }));
vi.mock("@/components/analytics/NsmCard", () => ({ NsmCard: probe("NsmCard") }));
// O funil global foi para o Command Center (PO, 20/10): se voltar a ser montado aqui, o probe aparece.
vi.mock("@/components/analytics/GlobalFunnelSection", () => ({ GlobalFunnelSection: probe("GlobalFunnelSection") }));
vi.mock("@/components/analytics/OpportunityInterestChart", () => ({ OpportunityInterestChart: probe("OpportunityInterestChart") }));
vi.mock("@/components/analytics/MatchHealthChart", () => ({ MatchHealthChart: probe("MatchHealthChart") }));
vi.mock("@/components/analytics/DemographicsCharts", () => ({ DemographicsCharts: probe("DemographicsCharts") }));
vi.mock("@/components/analytics/TopCoursesChart", () => ({ TopCoursesChart: probe("TopCoursesChart") }));
vi.mock("@/components/analytics/UserPreferencesChart", () => ({ UserPreferencesChart: probe("UserPreferencesChart") }));
vi.mock("@/components/analytics/LocationChart", () => ({ LocationChart: probe("LocationChart") }));
vi.mock("@/components/analytics/LocationPreferenceChart", () => ({ LocationPreferenceChart: probe("LocationPreferenceChart") }));
vi.mock("@/components/analytics/DateRangeFilter", () => ({
  DateRangeFilter: ({ onDateChange }: { onDateChange: (v: string) => void }) => (
    <>
      <button onClick={() => onDateChange("today")}>Hoje</button>
      <button onClick={() => onDateChange("90d")}>Últimos 90 dias</button>
    </>
  ),
}));
vi.mock("@/hooks/useAttributionFilterOptions", () => ({
  useAttributionFilterOptions: () => ({ options: { campaigns: [], channels: [] }, isLoading: false }),
}));
vi.mock("@/components/filters/AttributionFilterFields", () => ({
  AttributionFilterFields: ({ onChange }: { onChange: (f: object) => void }) => (
    <>
      <button onClick={() => onChange({ campaignId: CAMPAIGN })}>Escolher campanha</button>
      <button onClick={() => onChange({})}>Limpar</button>
    </>
  ),
}));

import Analytics from "./Analytics";

const SNAPSHOTS = ["MatchHealthChart", "DemographicsCharts", "TopCoursesChart", "UserPreferencesChart", "LocationChart", "LocationPreferenceChart"];

function Search() {
  return <div data-testid="search">{useLocation().search}</div>;
}
function renderAt(url = "/analytics") {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[url]}>
        <Analytics />
        <Search />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}
const props = (id: string) => JSON.parse(screen.getByTestId(id).textContent ?? "{}");
const callsOf = (name: string) => rpc.mock.calls.filter(([n]) => n === name).map(([, a]) => a);
const startOfToday = () => { const d = new Date(); d.setHours(0, 0, 0, 0); return d; };

beforeEach(() => {
  rpc.mockReset();
  rpc.mockImplementation(async (name: string) => {
    if (name === "get_product_l1_metrics") return { data: l1Fixture(), error: null };
    if (name === "get_product_l2_metrics") return { data: l2Fixture(), error: null };
    return { data: null, error: new Error(`rpc inesperada ${name}`) };
  });
});

describe("Analytics de Produto — seções", () => {
  it("mostra NSM, L1, L2, interesse por cliques e os retratos atuais, nesta ordem; sem funil global", async () => {
    renderAt();
    expect(screen.getByRole("heading", { level: 1, name: "Analytics de Produto" })).toBeInTheDocument();
    const nsm = screen.getByTestId("NsmCard");
    const l1 = await screen.findByRole("region", { name: /L1 — valor da feature/ });
    const l2 = screen.getByRole("region", { name: /L2 — qualidade do motor/ });
    const interest = screen.getByRole("region", { name: "Interesse por cliques" });
    expect(within(interest).getByTestId("OpportunityInterestChart")).toBeInTheDocument();
    const snap = screen.getByRole("region", { name: /Retrato atual \/ histórico disponível/ });
    expect(snap).toHaveTextContent("não limitado pelo período de atividade");
    for (const id of SNAPSHOTS) expect(within(snap).getByTestId(id)).toBeInTheDocument();
    const order = [nsm, l1, l2, interest, snap];
    for (let i = 1; i < order.length; i++)
      expect(order[i - 1].compareDocumentPosition(order[i]) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.queryByTestId("GlobalFunnelSection")).not.toBeInTheDocument();
  });

  it("período vai para L1, L2 e interesse; NSM e snapshots recebem só first-touch", async () => {
    renderAt();
    await screen.findByRole("region", { name: /L1 — valor da feature/ });
    const interest = props("OpportunityInterestChart");
    expect(Object.keys(interest).sort()).toEqual(["attribution", "dateRange"]);
    expect(interest.dateRange.from).toBeTruthy();
    expect(interest.dateRange.to).toBeTruthy();
    for (const id of ["NsmCard", ...SNAPSHOTS]) expect(Object.keys(props(id))).toEqual(["attribution"]);
    const range = { p_from: interest.dateRange.from, p_to: interest.dateRange.to };
    expect(callsOf("get_product_l1_metrics").at(-1)).toEqual(range);
    expect(callsOf("get_product_l2_metrics").at(-1)).toEqual(range);
  });

  it("mudar o período refaz L1, L2 e interesse e não toca a NSM nem os snapshots", async () => {
    renderAt();
    await screen.findByRole("region", { name: /L1 — valor da feature/ });
    const before = ["NsmCard", ...SNAPSHOTS].map((id) => screen.getByTestId(id).textContent);
    fireEvent.click(screen.getByText("Hoje"));
    const today = startOfToday().toISOString();
    await waitFor(() => expect(callsOf("get_product_l1_metrics").at(-1)?.p_from).toBe(today));
    expect(callsOf("get_product_l2_metrics").at(-1)?.p_from).toBe(today);
    expect(props("OpportunityInterestChart").dateRange.from).toBe(today);
    expect(["NsmCard", ...SNAPSHOTS].map((id) => screen.getByTestId(id).textContent)).toEqual(before);
  });

  it("first-touch vem da URL, chega a todas as seções e é gravado na URL", async () => {
    renderAt(`/analytics?campaignId=${CAMPAIGN}`);
    await screen.findByRole("region", { name: /L1 — valor da feature/ });
    for (const id of ["NsmCard", "OpportunityInterestChart", ...SNAPSHOTS])
      expect(props(id).attribution).toEqual({ campaignId: CAMPAIGN });
    expect(callsOf("get_product_l1_metrics").at(-1)).toMatchObject({ p_filter_campaign_id: CAMPAIGN });
    expect(callsOf("get_product_l2_metrics").at(-1)).toMatchObject({ p_filter_campaign_id: CAMPAIGN });

    fireEvent.click(screen.getByText("Limpar"));
    expect(screen.getByTestId("search")).toHaveTextContent(/^$/);
    fireEvent.click(screen.getByText("Escolher campanha"));
    expect(new URLSearchParams(screen.getByTestId("search").textContent ?? "").get("campaignId")).toBe(CAMPAIGN);
  });
});

describe("L1", () => {
  it("adoção da Cloudinha com conversaram/ativos e n, tempo até o início da 1ª candidatura e retenção por semestre", async () => {
    renderAt();
    const l1 = await screen.findByRole("region", { name: /L1 — valor da feature/ });
    const adoption = await within(l1).findByTestId("l1-adoption");
    expect(adoption).toHaveTextContent("25%");
    expect(adoption).toHaveTextContent("34 de 136 ativos");
    expect(adoption).toHaveTextContent("n = 136");
    expect(adoption).toHaveTextContent(/não system_intent/);
    const time = within(l1).getByTestId("l1-time");
    expect(time).toHaveTextContent("3,5 dias");
    expect(time).toHaveTextContent("p75 9 dias");
    expect(time).toHaveTextContent("n = 12");
    expect(time).toHaveTextContent(/início da primeira candidatura/);
    expect(time).toHaveTextContent(/não é tempo até submissão/);
    const table = within(l1).getByRole("table", { name: "Retenção por semestre" });
    const rows = within(table).getAllByRole("row");
    expect(rows[1]).toHaveTextContent("2025-S2");
    expect(rows[1]).toHaveTextContent("37,5%");
    expect(rows[2]).toHaveTextContent("2026-S1");
    expect(rows[2]).toHaveTextContent(/provisório/);
    expect(rows[2]).not.toHaveTextContent("0%");
    expect(within(l1).getByText(/Período de atividade em dias inteiros/)).toBeInTheDocument();
    expect(within(l1).getByText(/Sessão: primeiro registro observado em 17\/01\/2026/)).toBeInTheDocument();
  });

  it("taxa NULL é indisponível, não 0%", async () => {
    rpc.mockImplementation(async (name: string) => {
      if (name === "get_product_l1_metrics") {
        const d = l1Fixture();
        d.cloudinha_adoption = { talked: 0, active: 0, rate: null, n: 0 };
        d.time_to_first_application = { ...d.time_to_first_application, n: 0, median_days: null, p75_days: null };
        return { data: d, error: null };
      }
      return { data: l2Fixture(), error: null };
    });
    renderAt();
    const adoption = await screen.findByTestId("l1-adoption");
    expect(adoption).toHaveTextContent("Indisponível");
    expect(adoption).not.toHaveTextContent("0%");
    expect(screen.getByTestId("l1-time")).toHaveTextContent("Sem candidaturas iniciadas no período");
  });

  it("erro da L1 aparece em PT-BR sem derrubar o resto da página", async () => {
    rpc.mockImplementation(async (name: string) =>
      name === "get_product_l1_metrics" ? { data: null, error: new Error("denied") } : { data: l2Fixture(), error: null });
    renderAt();
    const l1 = screen.getByRole("region", { name: /L1 — valor da feature/ });
    expect(await within(l1).findByRole("alert")).toHaveTextContent("Não foi possível carregar a L1");
    expect(await screen.findByTestId("l2-temporal")).toBeInTheDocument();
  });
});

describe("L2", () => {
  it("alcance e cobertura de catálogo por domínio, rotulados como snapshot atual", async () => {
    renderAt();
    const l2 = await screen.findByRole("region", { name: /L2 — qualidade do motor/ });
    const reach = await within(l2).findByRole("table", { name: "Alcance do motor" });
    const [, mec, partner] = within(reach).getAllByRole("row");
    expect(mec).toHaveTextContent("MEC");
    expect(mec).toHaveTextContent("60 de 136");
    expect(mec).toHaveTextContent("44,1%");
    expect(partner).toHaveTextContent("Parceiro");
    expect(partner).toHaveTextContent("Indisponível");
    const catalog = within(l2).getByRole("table", { name: "Cobertura de catálogo" });
    expect(catalog).toHaveTextContent("900 de 210.952");
    expect(catalog).toHaveTextContent("7 de 8");
    expect(l2).toHaveTextContent("ativos no período com resultado atual");
    expect(l2).toHaveTextContent(/Snapshot atual de 20\/10\/2026/);
    expect(l2).toHaveTextContent(/5 linhas de match de perfis sem elo comprovado/);
  });

  it("contribuição temporal \"desde <data>\" separada da associação sem ordem temporal, nunca somadas", async () => {
    renderAt();
    const temporal = await screen.findByTestId("l2-temporal");
    expect(temporal).toHaveTextContent("desde 19/10/2026");
    expect(temporal).toHaveTextContent("3 de 11");
    expect(temporal).toHaveTextContent("27,3%");
    expect(temporal).toHaveTextContent(/observada/);
    expect(temporal).toHaveTextContent(/1 falha de captura/);
    const untimed = screen.getByTestId("l2-untimed");
    expect(untimed).toHaveTextContent("associação sem ordem temporal");
    expect(untimed).toHaveTextContent("40");
    expect(untimed).toHaveTextContent(/não somada/);
    expect(temporal).not.toHaveTextContent("40");
    expect(untimed).not.toHaveTextContent("3 de 11");
    expect(screen.queryByText(/\b43\b/)).not.toBeInTheDocument();
    expect(screen.queryByText(/\b51\b/)).not.toBeInTheDocument();
  });

  it("sem ativação do ledger, a contribuição temporal fica indisponível", async () => {
    rpc.mockImplementation(async (name: string) => {
      if (name === "get_product_l2_metrics") {
        const d = l2Fixture();
        d.match_contribution.temporal = { ...d.match_contribution.temporal, conversions_with_prior_match: 0, conversions_total: 0, rate: null, since: null };
        return { data: d, error: null };
      }
      return { data: l1Fixture(), error: null };
    });
    renderAt();
    const temporal = await screen.findByTestId("l2-temporal");
    expect(temporal).toHaveTextContent(/Captura ainda não ativada/);
    expect(temporal).not.toHaveTextContent("0%");
  });
});
