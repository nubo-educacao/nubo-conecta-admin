// Command Center — recorte por campanha/divulgador (first-touch). Contrato do
// TP-7: os parâmetros só viajam quando há filtro ativo; sem filtro, toda
// chamada fica idêntica à de antes (corpo das Edge Functions e args das RPCs).
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, renderHook, screen, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { supabase } from "@/integrations/supabase/client";
import {
  fetchDashboardStats,
  fetchActivityData,
  fetchTopCourses,
  fetchUserPreferences,
  fetchTopUsers,
  fetchLocationData,
  fetchCommandCenterDemographics,
} from "@/lib/analytics-queries";
import { fetchOpportunityInterest } from "@/services/opportunityInterestService";
import { attributionArg, attributionEdgeBody, attributionQueryKey } from "@/lib/commandCenterAttribution";
import {
  useDashboardStats,
  useActivityData,
  useTopCourses,
  useCommandCenterDemographics,
  useUserPreferences,
  useTopUsers,
  useLocationData,
} from "@/hooks/useAnalyticsData";
import { ActivityChart } from "@/components/analytics/ActivityChart";
import { LocationPreferenceChart } from "@/components/analytics/LocationPreferenceChart";
import { OpportunityInterestChart } from "@/components/analytics/OpportunityInterestChart";
import { DashboardHeader } from "@/components/analytics/DashboardHeader";

vi.mock("@/integrations/supabase/client", () => ({
  supabase: { rpc: vi.fn(), functions: { invoke: vi.fn() } },
}));
vi.mock("@/hooks/useAttributionFilterOptions", () => ({
  useAttributionFilterOptions: () => ({
    options: { campaigns: [{ id: CAMPAIGN, name: "Insper 2026" }], channels: [{ id: CHANNEL, name: "Influencer X" }] },
    isLoading: false,
  }),
}));
vi.mock("@/components/analytics/SegmentedExportButton", () => ({ default: () => null }));

const CAMPAIGN = "11111111-1111-1111-1111-111111111111";
const CHANNEL = "22222222-2222-2222-2222-222222222222";
const range = { from: new Date("2026-10-01T03:00:00Z"), to: new Date("2026-10-09T03:00:00Z") };

const invoke = vi.mocked(supabase.functions.invoke);
const rpc = vi.mocked(supabase.rpc);

beforeEach(() => {
  invoke.mockReset();
  invoke.mockResolvedValue({ data: [], error: null } as never);
  rpc.mockReset();
  rpc.mockResolvedValue({ data: [], error: null } as never);
});

const newClient = () => new QueryClient({ defaultOptions: { queries: { retry: false } } });
const wrapperFor = (client: QueryClient) => ({ children }: { children: ReactNode }) =>
  <QueryClientProvider client={client}>{children}</QueryClientProvider>;

describe("helpers de recorte do Command Center", () => {
  it("corpo das Edge Functions só leva o recorte quando ativo", () => {
    expect(attributionEdgeBody()).toEqual({});
    expect(attributionEdgeBody({})).toEqual({});
    expect(attributionEdgeBody({ unattributed: false })).toEqual({});
    expect(attributionEdgeBody({ campaignId: CAMPAIGN })).toEqual({ campaignId: CAMPAIGN });
    expect(attributionEdgeBody({ campaignId: CAMPAIGN, channelId: CHANNEL })).toEqual({ campaignId: CAMPAIGN, channelId: CHANNEL });
    expect(attributionEdgeBody({ campaignId: CAMPAIGN, unattributed: true })).toEqual({ unattributed: true });
  });
  it("chave de cache distingue recortes e é null sem filtro", () => {
    expect(attributionQueryKey()).toBeNull();
    expect(attributionQueryKey({})).toBeNull();
    expect(attributionQueryKey({ channelId: CHANNEL })).toEqual({
      p_filter_campaign_id: null, p_filter_channel_id: CHANNEL, p_filter_unattributed: null,
    });
  });
  it("argumento extra só existe com filtro ativo", () => {
    expect(attributionArg()).toEqual([]);
    expect(attributionArg({})).toEqual([]);
    expect(attributionArg({ unattributed: true })).toEqual([{ unattributed: true }]);
  });
});

describe("fetchers: baseline inalterado e recorte só quando ativo", () => {
  it.each([
    ["analytics-stats", () => fetchDashboardStats(range), { dateRange: range }],
    ["analytics-activity", () => fetchActivityData(range), { mode: "week", dateRange: range, timeZone: expect.any(String) }],
    ["analytics-rankings", () => fetchTopCourses(), { type: "courses" }],
    ["analytics-rankings", () => fetchUserPreferences(), { type: "preferences" }],
    ["analytics-rankings", () => fetchTopUsers(range), { type: "users", dateRange: range }],
    ["analytics-rankings", () => fetchLocationData(), { type: "locations" }],
  ] as const)("sem filtro: %s com o corpo de antes", async (fn, call, body) => {
    await call();
    expect(invoke).toHaveBeenCalledWith(fn, { body });
    expect(Object.keys(invoke.mock.calls[0][1]!.body as object)).toEqual(Object.keys(body));
  });

  it.each([
    ["analytics-stats", () => fetchDashboardStats(range, { campaignId: CAMPAIGN }), { dateRange: range, campaignId: CAMPAIGN }],
    ["analytics-activity", () => fetchActivityData(range, { channelId: CHANNEL }),
      { mode: "week", dateRange: range, timeZone: expect.any(String), channelId: CHANNEL }],
    ["analytics-rankings", () => fetchTopCourses({ unattributed: true }), { type: "courses", unattributed: true }],
    ["analytics-rankings", () => fetchUserPreferences({ campaignId: CAMPAIGN, channelId: CHANNEL }),
      { type: "preferences", campaignId: CAMPAIGN, channelId: CHANNEL }],
    ["analytics-rankings", () => fetchTopUsers(range, { campaignId: CAMPAIGN }), { type: "users", dateRange: range, campaignId: CAMPAIGN }],
    ["analytics-rankings", () => fetchLocationData({ channelId: CHANNEL }), { type: "locations", channelId: CHANNEL }],
  ] as const)("com filtro: %s recebe o recorte no corpo", async (fn, call, body) => {
    await call();
    expect(invoke).toHaveBeenCalledWith(fn, { body });
  });

  it("demografia: sem filtro chama a RPC só pelo nome; com filtro manda os três parâmetros", async () => {
    await fetchCommandCenterDemographics();
    expect(rpc).toHaveBeenLastCalledWith("get_command_center_demographics");
    await fetchCommandCenterDemographics({ unattributed: true });
    expect(rpc).toHaveBeenLastCalledWith("get_command_center_demographics", {
      p_filter_campaign_id: null, p_filter_channel_id: null, p_filter_unattributed: true,
    });
  });

  it("interesse por oportunidade: args de antes sem filtro; p_filter_* no fim com filtro", async () => {
    await fetchOpportunityInterest(range);
    expect(rpc).toHaveBeenLastCalledWith("get_command_center_opportunity_interest", {
      p_from: range.from.toISOString(), p_to: range.to.toISOString(), p_limit: 10,
    });
    await fetchOpportunityInterest(range, { campaignId: CAMPAIGN, channelId: CHANNEL });
    expect(rpc).toHaveBeenLastCalledWith("get_command_center_opportunity_interest", {
      p_from: range.from.toISOString(), p_to: range.to.toISOString(), p_limit: 10,
      p_filter_campaign_id: CAMPAIGN, p_filter_channel_id: CHANNEL, p_filter_unattributed: null,
    });
  });
});

describe("hooks: o recorte entra na chave de cache e na chamada", () => {
  it("cada hook do Command Center separa o cache por recorte", async () => {
    const client = newClient();
    const filter = { campaignId: CAMPAIGN };
    const key = attributionQueryKey(filter);
    renderHook(() => {
      useDashboardStats(range, filter);
      useActivityData(range, filter);
      useTopCourses(filter);
      useCommandCenterDemographics(filter);
      useUserPreferences(filter);
      useTopUsers(range, filter);
      useLocationData(filter);
    }, { wrapper: wrapperFor(client) });
    await waitFor(() => expect(invoke).toHaveBeenCalledTimes(6));
    const keys = client.getQueryCache().findAll().map((q) => q.queryKey);
    expect(keys).toHaveLength(7);
    for (const k of keys) expect(k.at(-1)).toEqual(key);
    for (const [, options] of invoke.mock.calls) expect((options as any).body.campaignId).toBe(CAMPAIGN);
    expect(rpc).toHaveBeenCalledWith("get_command_center_demographics", expect.objectContaining({ p_filter_campaign_id: CAMPAIGN }));
  });
  it("sem filtro a chave termina em null e a chamada é a de antes", async () => {
    const client = newClient();
    renderHook(() => { useTopCourses(); useCommandCenterDemographics(); }, { wrapper: wrapperFor(client) });
    await waitFor(() => expect(rpc).toHaveBeenCalled());
    expect(client.getQueryCache().findAll().map((q) => q.queryKey)).toEqual(
      expect.arrayContaining([["top-courses", null], ["command-center-demographics", null]]));
    expect(rpc).toHaveBeenCalledWith("get_command_center_demographics");
    expect(invoke).toHaveBeenCalledWith("analytics-rankings", { body: { type: "courses" } });
  });
});

describe("componentes com useQuery local", () => {
  const show = (ui: ReactNode) => render(<QueryClientProvider client={newClient()}>{ui}</QueryClientProvider>);

  it("ActivityChart envia o recorte no corpo e na chave", async () => {
    show(<ActivityChart dateRange={range} attribution={{ channelId: CHANNEL }} />);
    await waitFor(() => expect(invoke).toHaveBeenCalled());
    expect(invoke.mock.calls[0][0]).toBe("analytics-activity");
    expect(invoke.mock.calls[0][1]!.body).toMatchObject({ mode: "week", dateRange: range, channelId: CHANNEL });
  });
  it("ActivityChart sem recorte mantém o corpo de antes", async () => {
    show(<ActivityChart dateRange={range} />);
    await waitFor(() => expect(invoke).toHaveBeenCalled());
    expect(Object.keys(invoke.mock.calls[0][1]!.body as object).sort()).toEqual(["dateRange", "mode", "timeZone"]);
  });
  it("LocationPreferenceChart envia o recorte; sem ele, só o type", async () => {
    const first = show(<LocationPreferenceChart attribution={{ unattributed: true }} />);
    await waitFor(() => expect(invoke).toHaveBeenCalled());
    expect(invoke).toHaveBeenLastCalledWith("analytics-rankings", { body: { type: "location_preferences", unattributed: true } });
    first.unmount();
    invoke.mockClear();
    show(<LocationPreferenceChart />);
    await waitFor(() => expect(invoke).toHaveBeenCalled());
    expect(invoke).toHaveBeenLastCalledWith("analytics-rankings", { body: { type: "location_preferences" } });
  });
  it("OpportunityInterestChart recorta e avisa que só cliques de logados entram", async () => {
    show(<OpportunityInterestChart dateRange={range} attribution={{ campaignId: CAMPAIGN }} />);
    await waitFor(() => expect(rpc).toHaveBeenCalled());
    expect(rpc).toHaveBeenLastCalledWith("get_command_center_opportunity_interest", expect.objectContaining({ p_filter_campaign_id: CAMPAIGN }));
    expect(screen.getByText(/só entram cliques de usuários logados/i)).toBeInTheDocument();
  });
  it("OpportunityInterestChart sem recorte não mostra o aviso", async () => {
    show(<OpportunityInterestChart dateRange={range} />);
    await waitFor(() => expect(rpc).toHaveBeenCalled());
    expect(screen.queryByText(/só entram cliques de usuários logados/i)).not.toBeInTheDocument();
  });
});

describe("DashboardHeader", () => {
  it("renderiza campanha e divulgador na área de filtros e devolve o recorte escolhido", () => {
    const onAttributionChange = vi.fn();
    render(
      <DashboardHeader selectedRange="7d" onRangeChange={vi.fn()} onRefresh={vi.fn()} isRefreshing={false}
        lastUpdate={new Date()} attribution={{ unattributed: true }} onAttributionChange={onAttributionChange} />,
    );
    expect(screen.getByLabelText("Campanha")).toBeInTheDocument();
    expect(screen.getByLabelText("Divulgador")).toBeDisabled();
    expect(screen.getByText(/first-touch/)).toBeInTheDocument();
  });
  it("sem as props de recorte, não renderiza os seletores (uso legado)", () => {
    render(<DashboardHeader selectedRange="7d" onRangeChange={vi.fn()} onRefresh={vi.fn()} isRefreshing={false} lastUpdate={new Date()} />);
    expect(screen.queryByLabelText("Campanha")).not.toBeInTheDocument();
  });
});
