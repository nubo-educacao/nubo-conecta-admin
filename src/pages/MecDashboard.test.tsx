import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, useLocation } from "react-router-dom";
import { getMecDashboard, getMecOpportunityVolumes, getMecVolumeInstitutions } from "@/services/mecDashboardService";
import type { MecVolumeRow, MecVolumes } from "@/types/productAnalytics";

vi.mock("@/components/ui/select", () => import("@/test/selectShim"));
// importOriginal below loads the real service, which imports the client: keep it off the env (VITE_SUPABASE_*).
vi.mock("@/integrations/supabase/client", () => ({ supabase: {} }));
vi.mock("@/services/mecDashboardService", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/services/mecDashboardService")>()),
  getMecDashboard: vi.fn(),
  getMecOpportunityVolumes: vi.fn(),
  getMecVolumeInstitutions: vi.fn(),
}));
import MecDashboard from "@/pages/MecDashboard";

const UUID_A = "11111111-1111-4111-8111-111111111111";
const UUID_B = "22222222-2222-4222-8222-222222222222";
const instrumented = { status: "instrumented" as const, verified_since: "2026-10-01T12:00:00Z", first_observed_at: "2026-10-01T13:00:00Z" };
const dashboard = (over: Record<string, unknown> = {}) => ({
  totals: { card_view: 2, card_click: 8, redirect: 12, distinct_users: 1, distinct_identities: 2 },
  cohort: { viewers: 2, clickers: 1, redirectors: 0 },
  coverage: { first_observed_at: null, first_view_at: null, legacy_events: 7, redirect: instrumented },
  period: { from: "2026-09-20T15:00:00Z", to: "2026-10-20T15:00:00Z" },
  entities: [],
  ...over,
});
const row = (over: Partial<MecVolumeRow> = {}): MecVolumeRow => ({
  unified_opportunity_id: "mec_" + UUID_A, entity_id: UUID_A, course_title: "Medicina", institution_name: "UFMG",
  location: "Belo Horizonte - Campus Saúde", type: "prouni", card_view: 40, card_click: 9, redirect: 3,
  distinct_users: 5, distinct_identities: 7, in_catalog: true, ...over,
});
const volumes = (over: Partial<MecVolumes> = {}): MecVolumes => ({
  total_count: 2, limit: 25, offset: 0, order: "views",
  rows: [row(), row({ unified_opportunity_id: "mec_" + UUID_B, entity_id: UUID_B, course_title: null, institution_name: null, location: null, type: null, in_catalog: false, card_view: 1 })],
  non_additive_notice: "Pessoas podem aparecer em várias oportunidades; contagens por oportunidade não são aditivas.",
  ...over,
});

let currentSearch = "";
function LocationProbe() { currentSearch = useLocation().search; return null; }
function renderPage(initial = "/educational/mec-dashboard") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={client}><MemoryRouter initialEntries={[initial]}><MecDashboard /><LocationProbe /></MemoryRouter></QueryClientProvider>);
}

beforeEach(() => {
  vi.mocked(getMecDashboard).mockReset().mockResolvedValue(dashboard() as never);
  vi.mocked(getMecOpportunityVolumes).mockReset().mockResolvedValue(volumes());
  vi.mocked(getMecVolumeInstitutions).mockReset().mockResolvedValue([{ id: "inst-ufmg", name: "UFMG" }]);
});
afterEach(() => { cleanup(); vi.useRealTimers(); });

describe("MEC funnel (sequential cohort)", () => {
  it("draws viewers → clickers → redirectors as a cohort chart and keeps the table as detail", async () => {
    renderPage();
    const chart = await screen.findByRole("img", { name: /Funil de coorte sequencial/ });
    expect(within(chart).getAllByTestId("funnel-step").map((s) => s.getAttribute("data-step"))).toEqual(["viewers", "clickers", "redirectors"]);
    expect(within(chart).getByText(/Conversão da coorte: 50%/)).toBeInTheDocument();
    expect(screen.getByRole("table", { name: "Detalhe da coorte MEC" })).toBeInTheDocument();
    expect(screen.getByText(/não confirma candidatura concluída/)).toBeInTheDocument();
    expect(screen.getByText(/par identidade \+ oportunidade/)).toBeInTheDocument();
    // Event totals stay apart from the cohort and can be non-monotonic.
    expect(screen.getByTestId("mec-total-redirect")).toHaveTextContent("12");
  });

  it("instrumented window with no redirect is a measured zero", async () => {
    renderPage();
    const chart = await screen.findByRole("img", { name: /Funil de coorte sequencial/ });
    expect(chart).toHaveAccessibleName(/Redirect ao portal oficial: 0/);
    expect(within(chart).getByText(/Conversão da coorte: 0%/)).toBeInTheDocument();
  });

  it("unknown coverage with no redirect is 'não instrumentado', never 0", async () => {
    vi.mocked(getMecDashboard).mockResolvedValue(dashboard({ coverage: { first_observed_at: null, first_view_at: null, legacy_events: 0, redirect: { status: "unknown", verified_since: null, first_observed_at: null } } }) as never);
    renderPage();
    const chart = await screen.findByRole("img", { name: /Funil de coorte sequencial/ });
    expect(chart).toHaveAccessibleName(/Redirect ao portal oficial: indisponível/);
    expect(within(chart).getByText("Não instrumentado")).toBeInTheDocument();
    expect(screen.getByText(/nenhum redirect observado/)).toBeInTheDocument();
  });

  it("unknown coverage with observed redirects labels the first observation, not a deploy date, and hides the rate", async () => {
    vi.mocked(getMecDashboard).mockResolvedValue(dashboard({ cohort: { viewers: 4, clickers: 2, redirectors: 1 }, coverage: { first_observed_at: null, first_view_at: null, legacy_events: 0, redirect: { status: "unknown", verified_since: null, first_observed_at: "2026-10-18T13:00:00Z" } } }) as never);
    renderPage();
    const chart = await screen.findByRole("img", { name: /Funil de coorte sequencial/ });
    expect(chart).toHaveAccessibleName(/Redirect ao portal oficial: 1/);
    expect(within(chart).getAllByText(/Conversão da coorte/)).toHaveLength(1); // only clickers/viewers
    expect(screen.getByText(/Primeiro redirect observado em 18\/10\/2026 10:00 \(não é a data de instrumentação\)/)).toBeInTheDocument();
  });

  it("not_instrumented and partial windows are distinguished", async () => {
    vi.mocked(getMecDashboard).mockResolvedValue(dashboard({ coverage: { first_observed_at: null, first_view_at: null, legacy_events: 0, redirect: { status: "not_instrumented", verified_since: "2026-10-30T03:00:00Z", first_observed_at: null } } }) as never);
    renderPage();
    expect(await screen.findByText(/não instrumentado antes de 30\/10\/2026 00:00/)).toBeInTheDocument();
    cleanup();
    vi.mocked(getMecDashboard).mockResolvedValue(dashboard({ cohort: { viewers: 4, clickers: 2, redirectors: 1 }, coverage: { first_observed_at: null, first_view_at: null, legacy_events: 0, redirect: { status: "partial", verified_since: "2026-10-10T03:00:00Z", first_observed_at: "2026-10-10T04:00:00Z" } } }) as never);
    renderPage();
    const chart = await screen.findByRole("img", { name: /Funil de coorte sequencial/ });
    expect(within(chart).getByText("Cobertura parcial — volume observado")).toBeInTheDocument();
    expect(screen.getByText(/Cobertura parcial: redirect medido só a partir de 10\/10\/2026 00:00/)).toBeInTheDocument();
  });

  it("period 7/30/90/all drives the cohort and the volumes use the server's normalized window", async () => {
    renderPage();
    await screen.findByRole("img", { name: /Funil de coorte sequencial/ });
    expect(getMecDashboard).toHaveBeenCalledWith(undefined, 30);
    await waitFor(() => expect(getMecOpportunityVolumes).toHaveBeenCalled());
    expect(vi.mocked(getMecOpportunityVolumes).mock.calls[0][0]).toMatchObject({
      range: { from: new Date("2026-09-20T15:00:00Z"), to: new Date("2026-10-20T15:00:00Z") }, offset: 0, limit: 25, order: "views",
    });
    expect([...screen.getByLabelText("Período").querySelectorAll("option")].map((o) => o.value)).toEqual(["7", "30", "90", "all"]);
    vi.mocked(getMecDashboard).mockResolvedValue(dashboard({ period: { from: null, to: "2026-10-20T15:05:00Z" } }) as never);
    fireEvent.change(screen.getByLabelText("Período"), { target: { value: "all" } });
    await waitFor(() => expect(getMecDashboard).toHaveBeenLastCalledWith(undefined, null));
    await waitFor(() => expect(vi.mocked(getMecOpportunityVolumes).mock.lastCall?.[0]).toMatchObject({ range: { from: undefined, to: new Date("2026-10-20T15:05:00Z") }, offset: 0 }));
    expect(getMecVolumeInstitutions).toHaveBeenLastCalledWith({ from: undefined, to: new Date("2026-10-20T15:05:00Z") });
    expect(screen.getByText(/Janela: Todo o histórico/)).toBeInTheDocument();
  });

  it("shows every date on the page in Brasília time, whatever the browser zone", async () => {
    vi.mocked(getMecDashboard).mockResolvedValue(dashboard({ coverage: { first_observed_at: "2026-10-01T02:30:00Z", first_view_at: null, legacy_events: 0, redirect: instrumented } }) as never);
    renderPage();
    expect(await screen.findByText(/Primeiro evento MEC observado: 30\/09\/2026 23:30/)).toBeInTheDocument();
    expect(screen.getByText(/Janela: 20\/09\/2026 12:00 até 20\/10\/2026 12:00 \(horário de Brasília\)/)).toBeInTheDocument();
    expect(screen.getByText(/verificado desde 01\/10\/2026 09:00/)).toBeInTheDocument();
  });

  it("shows denied/network failure as an error, with retry, never as an empty dataset", async () => {
    vi.mocked(getMecDashboard).mockRejectedValue(new Error("denied"));
    renderPage();
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível carregar");
    expect(screen.getByRole("button", { name: "Tentar novamente" })).toBeInTheDocument();
    expect(screen.queryByRole("img", { name: /Funil de coorte/ })).not.toBeInTheDocument();
  });
});

describe("MEC volumes by opportunity", () => {
  it("shows names, campus and modality, no UUID, and labels out-of-catalog rows", async () => {
    renderPage();
    const table = await screen.findByRole("table", { name: "Volumes por oportunidade MEC" });
    await within(table).findByText("Medicina");
    const first = within(table).getAllByRole("row")[1];
    expect(within(first).getAllByRole("cell").map((c) => c.textContent)).toEqual(["Medicina", "UFMG", "Belo Horizonte - Campus Saúde", "ProUni", "40", "9", "3", "7", "5"]);
    expect(within(table).getByText("fora do catálogo atual")).toBeInTheDocument();
    expect(document.body.textContent).not.toContain(UUID_A);
    expect(document.body.textContent).not.toContain(UUID_B);
    expect(screen.getByText("Usuários e eventos não são aditivos entre oportunidades.")).toBeInTheDocument();
    expect(screen.getByText("1–2 de 2")).toBeInTheDocument();
    expect(screen.getByTestId("mec-volumes-range")).toHaveAttribute("aria-live", "polite");
  });

  it("paginates on the server and shows 26–50 de N", async () => {
    vi.mocked(getMecOpportunityVolumes).mockImplementation(async (o) => volumes({ total_count: 60, offset: o?.offset ?? 0, rows: Array.from({ length: 25 }, (_, i) => row({ unified_opportunity_id: `mec_${i}`, entity_id: `${i}`, course_title: `Curso ${(o?.offset ?? 0) + i + 1}` })) }));
    renderPage();
    expect(await screen.findByText("1–25 de 60")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Próxima" }));
    expect(await screen.findByText("26–50 de 60")).toBeInTheDocument();
    expect(vi.mocked(getMecOpportunityVolumes).mock.lastCall?.[0]).toMatchObject({ offset: 25, limit: 25 });
    expect(currentSearch).toContain("pagina=2");
    expect(screen.getByRole("button", { name: "Anterior" })).toBeEnabled();
  });

  it("an empty page keeps the server total", async () => {
    vi.mocked(getMecOpportunityVolumes).mockResolvedValue(volumes({ total_count: 30, offset: 50, rows: [] }));
    renderPage("/educational/mec-dashboard?pagina=3");
    expect(await screen.findByText("Nenhuma linha nesta página · 30 no total")).toBeInTheDocument();
    expect(vi.mocked(getMecOpportunityVolumes).mock.lastCall?.[0]).toMatchObject({ offset: 50 });
  });

  it("search is debounced 300 ms, resets the page and lives in the URL", async () => {
    renderPage("/educational/mec-dashboard?pagina=2");
    await screen.findByRole("table", { name: "Volumes por oportunidade MEC" });
    await waitFor(() => expect(getMecOpportunityVolumes).toHaveBeenCalled());
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const calls = vi.mocked(getMecOpportunityVolumes).mock.calls.length;
    fireEvent.change(screen.getByLabelText("Buscar curso ou instituição"), { target: { value: "medicina" } });
    await act(async () => { vi.advanceTimersByTime(200); });
    expect(vi.mocked(getMecOpportunityVolumes).mock.calls.length).toBe(calls);
    await act(async () => { vi.advanceTimersByTime(150); });
    vi.useRealTimers();
    await waitFor(() => expect(vi.mocked(getMecOpportunityVolumes).mock.lastCall?.[0]).toMatchObject({ search: "medicina", offset: 0 }));
    expect(currentSearch).toContain("busca=medicina");
    expect(currentSearch).not.toContain("pagina=");
  });

  it("type, institution and sort refetch with the right args and reset the page", async () => {
    renderPage("/educational/mec-dashboard?pagina=2");
    await screen.findByRole("table", { name: "Volumes por oportunidade MEC" });
    fireEvent.change(await screen.findByLabelText("Modalidade"), { target: { value: "prouni" } });
    await waitFor(() => expect(vi.mocked(getMecOpportunityVolumes).mock.lastCall?.[0]).toMatchObject({ type: "prouni", offset: 0 }));
    await waitFor(() => expect(screen.getByLabelText("Instituição")).toContainHTML("UFMG"));
    fireEvent.change(screen.getByLabelText("Instituição"), { target: { value: "inst-ufmg" } });
    await waitFor(() => expect(vi.mocked(getMecOpportunityVolumes).mock.lastCall?.[0]).toMatchObject({ institutionId: "inst-ufmg", type: "prouni" }));
    fireEvent.click(screen.getByRole("button", { name: /Ordenar por redirects/ }));
    await waitFor(() => expect(vi.mocked(getMecOpportunityVolumes).mock.lastCall?.[0]).toMatchObject({ order: "redirects", offset: 0 }));
    expect(screen.getByRole("columnheader", { name: /Redirects/ })).toHaveAttribute("aria-sort", "descending");
    for (const [label, order] of [["views", "views"], ["cliques", "clicks"], ["pessoas distintas", "users"]] as const) {
      fireEvent.click(screen.getByRole("button", { name: new RegExp(`Ordenar por ${label}`) }));
      await waitFor(() => expect(vi.mocked(getMecOpportunityVolumes).mock.lastCall?.[0]).toMatchObject({ order }));
    }
    expect(currentSearch).toContain("modalidade=prouni");
    expect(currentSearch).toContain("instituicao=inst-ufmg");
    expect(currentSearch).toContain("ordem=users");
  });

  it("restores filters from the URL", async () => {
    renderPage("/educational/mec-dashboard?busca=direito&modalidade=sisu&ordem=clicks&pagina=2");
    await waitFor(() => expect(vi.mocked(getMecOpportunityVolumes).mock.lastCall?.[0]).toMatchObject({ search: "direito", type: "sisu", order: "clicks", offset: 25 }));
    expect(screen.getByLabelText("Buscar curso ou instituição")).toHaveValue("direito");
  });

  it("unmeasured redirect coverage shows n/i in the redirect column instead of 0", async () => {
    vi.mocked(getMecDashboard).mockResolvedValue(dashboard({ totals: { card_view: 2, card_click: 1, redirect: 0, distinct_users: 1, distinct_identities: 1 }, coverage: { first_observed_at: null, first_view_at: null, legacy_events: 0, redirect: { status: "unknown", verified_since: null, first_observed_at: null } } }) as never);
    vi.mocked(getMecOpportunityVolumes).mockResolvedValue(volumes({ rows: [row({ redirect: 0 })], total_count: 1 }));
    renderPage();
    const table = await screen.findByRole("table", { name: "Volumes por oportunidade MEC" });
    await within(table).findByText("Medicina");
    const first = within(table).getAllByRole("row")[1];
    expect(within(first).getAllByRole("cell")[6]).toHaveTextContent("n/i");
  });

  it("volume errors are errors, not an empty catalog", async () => {
    vi.mocked(getMecOpportunityVolumes).mockRejectedValue(new Error("denied"));
    renderPage();
    expect(await screen.findByText("Não foi possível carregar os volumes MEC.")).toBeInTheDocument();
    expect(screen.queryByText(/Nenhuma oportunidade MEC com eventos/)).not.toBeInTheDocument();
  });
});

describe("MEC opportunity selector", () => {
  it("lists course + institution names and queries the dashboard by entity_id without mec_", async () => {
    renderPage();
    const select = await screen.findByLabelText("Oportunidade MEC");
    await waitFor(() => expect(select).toContainHTML("Medicina — UFMG"));
    expect(select.textContent).not.toContain(UUID_A);
    expect(select.textContent).toContain("Oportunidade fora do catálogo atual");
    fireEvent.change(select, { target: { value: UUID_A } });
    await waitFor(() => expect(getMecDashboard).toHaveBeenLastCalledWith(UUID_A, 30));
    expect(vi.mocked(getMecDashboard).mock.calls.every(([id]) => !id || !id.startsWith("mec_"))).toBe(true);
  });
});
