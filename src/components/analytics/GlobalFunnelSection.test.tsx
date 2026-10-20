import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { GlobalFunnelSection } from "./GlobalFunnelSection";
import { fetchGlobalFunnel } from "@/services/productAnalyticsService";
import type {
  DomainFunnel,
  FunnelStepKey,
  GlobalFunnel,
  InstrumentationCoverage,
} from "@/types/productAnalytics";

vi.mock("@/services/productAnalyticsService", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/services/productAnalyticsService")>()),
  fetchGlobalFunnel: vi.fn(),
}));

const OBSERVED: InstrumentationCoverage = {
  status: "observed",
  reason: "Volumes observados; não representam coorte sequencial",
};
const UNKNOWN: InstrumentationCoverage = {
  status: "unknown",
  verified_since: null,
  first_observed_at: null,
};
const LABELS: Record<FunnelStepKey, string> = {
  card_view: "Visualizações",
  card_click: "Cliques",
  terminal: "Encaminhamentos",
};
const KEYS: FunnelStepKey[] = ["card_view", "card_click", "terminal"];

function domain(
  counts: [number, number, number],
  users: [number, number, number],
  options: {
    terminalCoverage?: InstrumentationCoverage;
    ratios?: [number | null, number | null];
    composition?: DomainFunnel["composition_events"];
  } = {},
): DomainFunnel {
  return {
    steps: KEYS.map((key, i) => ({
      key,
      label: LABELS[key],
      events: counts[i],
      users: users[i],
      coverage: key === "terminal" ? (options.terminalCoverage ?? OBSERVED) : OBSERVED,
    })),
    volume_ratios: [
      {
        from: "card_view",
        to: "card_click",
        events_ratio: options.ratios?.[0] ?? counts[1] / counts[0],
        users_ratio: null,
        kind: "observed_volume_ratio",
      },
      {
        from: "card_click",
        to: "terminal",
        events_ratio: options.ratios?.[1] ?? counts[2] / counts[1],
        users_ratio: null,
        kind: "observed_volume_ratio",
      },
    ],
    composition_events: options.composition ?? null,
  };
}

function funnel(overrides: Partial<GlobalFunnel> = {}): GlobalFunnel {
  const mec = domain([100, 20, 5], [40, 10, 4]);
  const partner = domain([200, 50, 30], [80, 25, 20], {
    composition: { redirected: 20, submitted: 8, legacy_external_redirect: 2 },
  });
  return {
    period: { from: "2026-10-01T03:00:00Z", to: "2026-10-10T03:00:00Z" },
    unit_note:
      "Eventos são somáveis. Candidaturas anteriores à captura usam created_at como proxy de data, não a data de submissão.",
    domains: { mec, partner },
    totals_by_step: KEYS.map((key, i) => ({
      key,
      events: mec.steps[i].events + partner.steps[i].events,
      distinct_identities: [100, 30, 22][i],
      domain_identity_sum: mec.steps[i].users + partner.steps[i].users,
      people_composition_additive: false as const,
      coverage: { status: "observed" as const, mec_redirect: OBSERVED },
    })),
    by_surface: [
      {
        surface: "home_carrossel_oportunidades",
        domain: "partner",
        views: 76,
        clicks: 12,
        clicks_instrumented: 12,
        coverage: OBSERVED,
      },
    ],
    ...overrides,
  };
}

function show(
  props: Partial<React.ComponentProps<typeof GlobalFunnelSection>> = {},
) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const tree = (p: typeof props) => (
    <QueryClientProvider client={client}>
      <GlobalFunnelSection
        range={{ from: new Date("2026-10-01T03:00:00Z"), to: new Date("2026-10-10T03:00:00Z") }}
        {...p}
      />
    </QueryClientProvider>
  );
  const view = render(tree(props));
  return { ...view, again: (p: typeof props) => view.rerender(tree(p)) };
}

beforeEach(() => {
  vi.mocked(fetchGlobalFunnel).mockReset();
});

describe("GlobalFunnelSection — eventos", () => {
  it("draws view → click → terminal with totals and stacked MEC / Parceiro parts", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(funnel());
    show();
    const rows = await screen.findAllByTestId("global-step");
    expect(rows.map((r) => r.getAttribute("data-step"))).toEqual(KEYS);
    expect(within(rows[0]).getByTestId("step-total")).toHaveTextContent("300");
    expect(within(rows[0]).getByTitle("MEC: 100")).toHaveStyle({ width: "33.33333333333333%" });
    expect(within(rows[0]).getByTitle("Parceiro: 200")).toBeInTheDocument();
    expect(within(rows[2]).getByTestId("step-total")).toHaveTextContent("35");
    expect(screen.getByText("Unidade: eventos (soma de event_count)", { exact: false })).toBeInTheDocument();
  });

  it("keeps a terminal larger than the click step, with no clamp or reordering", async () => {
    const mec = domain([100, 10, 70], [40, 8, 30]);
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(
      funnel({
        domains: { mec, partner: domain([200, 50, 30], [80, 25, 20]) },
        totals_by_step: funnel().totals_by_step.map((t, i) => ({
          ...t,
          events: mec.steps[i].events + [200, 50, 30][i],
        })),
      }),
    );
    show();
    const rows = await screen.findAllByTestId("global-step");
    expect(rows.map((r) => r.getAttribute("data-step"))).toEqual(KEYS);
    expect(within(rows[1]).getByTestId("step-total")).toHaveTextContent("60");
    expect(within(rows[2]).getByTestId("step-total")).toHaveTextContent("100");
    const mecPanel = screen.getByTestId("domain-mec");
    expect(within(mecPanel).getByText(/Razão de volumes observados: 700%/)).toBeInTheDocument();
  });

  it("shows the partner terminal as redirected / submitted / legacy v0 and counts it once", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(funnel());
    show();
    const panel = await screen.findByTestId("domain-partner");
    expect(within(panel).getByText("Redirecionadas: 20")).toBeInTheDocument();
    expect(within(panel).getByText("Enviadas: 8")).toBeInTheDocument();
    expect(within(panel).getByText("Legado v0 (redirect externo): 2")).toBeInTheDocument();
    // 20 + 8 + 2 = 30: terminal parceiro não soma partner_application de novo
    expect(within(panel).getAllByText("30").length).toBeGreaterThan(0);
  });

  it("keeps ratios inside each domain and never renders a combined one", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(funnel());
    show();
    await screen.findAllByTestId("global-step");
    const ratio = /Razão de volumes observados:/;
    expect(within(screen.getByTestId("domain-mec")).getAllByText(ratio)).toHaveLength(2);
    expect(within(screen.getByTestId("domain-partner")).getAllByText(ratio)).toHaveLength(2);
    expect(within(screen.getByTestId("global-funnel")).queryByText(ratio)).not.toBeInTheDocument();
    expect(screen.getAllByText(ratio)).toHaveLength(4);
    expect(screen.queryByText(/taxa (média|combinada|global)/i)).not.toBeInTheDocument();
  });
});

describe("GlobalFunnelSection — pessoas", () => {
  it("shows the server distinct total next to overlapping domain counts, never stacked", async () => {
    // a mesma identidade nos dois domínios: 1 distinta, 1 em cada domínio, soma por domínio 2
    const mec = domain([2, 1, 1], [1, 1, 1], { ratios: [0.5, 1] });
    const partner = domain([3, 1, 1], [1, 1, 1], { ratios: [0.33, 1] });
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(
      funnel({
        domains: { mec, partner },
        totals_by_step: KEYS.map((key, i) => ({
          key,
          events: mec.steps[i].events + partner.steps[i].events,
          distinct_identities: 1,
          domain_identity_sum: 2,
          people_composition_additive: false as const,
          coverage: { status: "observed" as const, mec_redirect: OBSERVED },
        })),
      }),
    );
    show();
    await screen.findAllByTestId("global-step");
    fireEvent.click(screen.getByRole("button", { name: "Pessoas" }));
    const rows = screen.getAllByTestId("global-step");
    expect(within(rows[0]).getByTestId("step-total")).toHaveTextContent("1");
    expect(within(rows[0]).getByText("MEC: 1")).toBeInTheDocument();
    expect(within(rows[0]).getByText("Parceiro: 1")).toBeInTheDocument();
    expect(within(rows[0]).getByText(/soma de contagens por domínio: 2/i)).toBeInTheDocument();
    expect(within(rows[0]).getByText(/não é total de pessoas únicas/i)).toBeInTheDocument();
    expect(screen.queryByTitle("MEC: 1")).not.toBeInTheDocument();
    expect(screen.getByText(/Unidade: identidades distintas observadas/)).toBeInTheDocument();
    expect(screen.getByText(/pessoas não são aditivas entre etapas nem entre domínios/i)).toBeInTheDocument();
  });
});

describe("GlobalFunnelSection — cobertura", () => {
  const withMecTerminal = (coverage: InstrumentationCoverage, events = 0, users = 0) => {
    const mec = domain([100, 20, events], [40, 10, users], { terminalCoverage: coverage, ratios: [0.2, null] });
    const partner = funnel().domains.partner;
    return funnel({
      domains: { mec, partner },
      totals_by_step: funnel().totals_by_step.map((t, i) => ({
        ...t,
        events: mec.steps[i].events + partner.steps[i].events,
        coverage: { status: "observed" as const, mec_redirect: coverage },
      })),
    });
  };

  it("does not show a measured zero for MEC terminal with unknown coverage and no verified_since", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(
      withMecTerminal({ status: "unknown", verified_since: null, first_observed_at: "2026-10-05T12:00:00Z" }),
    );
    show();
    const rows = await screen.findAllByTestId("global-step");
    const terminal = rows[2];
    expect(within(terminal).getByText("MEC: indisponível")).toBeInTheDocument();
    expect(within(terminal).queryByText("MEC: 0")).not.toBeInTheDocument();
    expect(within(terminal).getByTestId("step-total")).toHaveTextContent("30");
    expect(within(terminal).getByText(/soma das parcelas observadas/i)).toBeInTheDocument();
    expect(within(terminal).queryByText(/^total$/i)).not.toBeInTheDocument();
    expect(within(screen.getByTestId("coverage-notes")).getByText(/primeiro evento observado em 05\/10\/2026/i)).toBeInTheDocument();
    expect(screen.queryByText(/implantad/i)).not.toBeInTheDocument();
  });

  it("says 'não instrumentado antes de <data>' when the window precedes the verified start", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(
      withMecTerminal({ status: "not_instrumented", verified_since: "2026-10-20T03:00:00Z", first_observed_at: null }),
    );
    show();
    await screen.findAllByTestId("global-step");
    expect(within(screen.getByTestId("coverage-notes")).getByText(/não instrumentado antes de 20\/10\/2026/i)).toBeInTheDocument();
    expect(within(screen.getAllByTestId("global-step")[2]).getByText("MEC: indisponível")).toBeInTheDocument();
  });

  it("shows observed values with a partial-window warning and no complete total", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(
      withMecTerminal({ status: "partial", verified_since: "2026-10-06T03:00:00Z", first_observed_at: "2026-10-06T10:00:00Z" }, 3, 3),
    );
    show();
    const terminal = (await screen.findAllByTestId("global-step"))[2];
    expect(within(terminal).getByText("MEC: 3 (janela parcial)")).toBeInTheDocument();
    expect(within(terminal).getByTestId("step-total")).toHaveTextContent("33");
    expect(within(terminal).getByText(/soma das parcelas observadas/i)).toBeInTheDocument();
    expect(within(screen.getByTestId("coverage-notes")).getByText(/janela parcial/i)).toBeInTheDocument();
    // sem razão completa no domínio MEC para o terminal
    expect(within(screen.getByTestId("domain-mec")).getAllByText(/Razão de volumes observados:/)).toHaveLength(1);
  });

  it("shows a real zero when the window is fully instrumented", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(
      withMecTerminal({ status: "instrumented", verified_since: "2026-09-01T03:00:00Z", first_observed_at: null }, 0, 0),
    );
    show();
    const terminal = (await screen.findAllByTestId("global-step"))[2];
    expect(within(terminal).getByText("MEC: 0")).toBeInTheDocument();
    expect(within(terminal).getByText("Total")).toBeInTheDocument();
  });
});

describe("GlobalFunnelSection — jornada por superfície", () => {
  it("lists views and clicks per surface and domain, with historical click caveats", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(
      funnel({
        by_surface: [
          { surface: "oportunidades_lista", domain: "mec", views: 50, clicks: 0, clicks_instrumented: 0, coverage: { status: "not_instrumented", verified_since: "2026-10-20T03:00:00Z" } },
          { surface: "home_para_voce", domain: "partner", views: 9, clicks: 3, clicks_instrumented: 3, coverage: { status: "not_instrumented", verified_since: "2026-10-20T03:00:00Z" } },
          { surface: "não instrumentado por superfície", domain: "mec", views: 0, clicks: 106, clicks_instrumented: 0, coverage: { status: "not_instrumented", verified_since: "2026-10-20T03:00:00Z" } },
        ],
      }),
    );
    show();
    const table = await screen.findByRole("table", { name: /views e cliques por superfície/i });
    const rows = within(table).getAllByRole("row").slice(1);
    expect(rows).toHaveLength(3);
    expect(within(rows[0]).getByText("oportunidades_lista")).toBeInTheDocument();
    expect(within(rows[0]).getByText(/aba "Para Você"/)).toBeInTheDocument();
    expect(within(rows[0]).getByText("não instrumentado")).toBeInTheDocument();
    expect(within(rows[1]).getByText("home_para_voce")).toBeInTheDocument();
    expect(within(rows[2]).getByText("Não instrumentado por superfície")).toBeInTheDocument();
    expect(within(rows[2]).getByText("106")).toBeInTheDocument();
  });
});

describe("GlobalFunnelSection — consulta e estados", () => {
  it("passes period and first-touch and refetches when they change", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(funnel());
    const range = { from: new Date("2026-10-01T03:00:00Z"), to: new Date("2026-10-10T03:00:00Z") };
    const { again } = show({ range, attribution: { campaignId: "c1" } });
    await screen.findAllByTestId("global-step");
    expect(fetchGlobalFunnel).toHaveBeenCalledWith(range, { campaignId: "c1" });
    const next = { from: new Date("2026-09-01T03:00:00Z"), to: new Date("2026-09-30T03:00:00Z") };
    again({ range: next, attribution: { campaignId: "c1" } });
    await vi.waitFor(() => expect(fetchGlobalFunnel).toHaveBeenLastCalledWith(next, { campaignId: "c1" }));
    again({ range: next, attribution: { channelId: "ch" } });
    await vi.waitFor(() => expect(fetchGlobalFunnel).toHaveBeenLastCalledWith(next, { channelId: "ch" }));
    expect(fetchGlobalFunnel).toHaveBeenCalledTimes(3);
  });

  it("asks for the whole period when range is null", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(funnel());
    show({ range: null });
    await screen.findAllByTestId("global-step");
    expect(fetchGlobalFunnel).toHaveBeenCalledWith(undefined, undefined);
  });

  it("shows loading, then the server unit note with the created_at proxy", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(funnel());
    show();
    expect(screen.getByRole("status", { name: /carregando funil global/i })).toBeInTheDocument();
    expect(await screen.findByText(/created_at como proxy de data/i)).toBeInTheDocument();
  });

  it("shows an error in Portuguese, not an empty funnel", async () => {
    vi.mocked(fetchGlobalFunnel).mockImplementation(async () => {
      throw new Error("permission denied");
    });
    show();
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível carregar o funil global.");
    expect(screen.queryByText(/nenhum evento observado/i)).not.toBeInTheDocument();
  });

  it("shows an empty state that does not turn unknown coverage into zero", async () => {
    const empty = domain([0, 0, 0], [0, 0, 0], { terminalCoverage: UNKNOWN, ratios: [null, null] });
    vi.mocked(fetchGlobalFunnel).mockResolvedValue(
      funnel({
        domains: { mec: empty, partner: domain([0, 0, 0], [0, 0, 0], { ratios: [null, null] }) },
        totals_by_step: KEYS.map((key) => ({
          key, events: 0, distinct_identities: 0, domain_identity_sum: 0,
          people_composition_additive: false as const,
          coverage: { status: "observed" as const, mec_redirect: UNKNOWN },
        })),
        by_surface: [],
      }),
    );
    show();
    expect(await screen.findByText("Nenhum evento observado neste período.")).toBeInTheDocument();
    expect(within(screen.getByTestId("coverage-notes")).getByText(/cobertura desconhecida/i)).toBeInTheDocument();
    expect(screen.queryAllByTestId("global-step")).toHaveLength(0);
  });

  it("treats a response without domains as missing base, not as zero", async () => {
    vi.mocked(fetchGlobalFunnel).mockResolvedValue({ ...funnel(), domains: {} as never, totals_by_step: [] });
    show();
    expect(await screen.findByText(/sem base de dados do funil/i)).toBeInTheDocument();
  });
});
