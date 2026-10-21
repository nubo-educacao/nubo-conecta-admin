// NUB-RD-89d — NSM "encaminhamentos por aluno ativo" no Command Center.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { nsmFixture } from "@/test/productAnalyticsFixtures";

const { rpc } = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc } }));

import { NsmCard, adjacentSemester, currentSemester } from "./NsmCard";

const CAMPAIGN = "11111111-1111-1111-1111-111111111111";

function renderCard(attribution = {}) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <NsmCard attribution={attribution} />
    </QueryClientProvider>,
  );
}

const lastArgs = () => rpc.mock.calls.at(-1)?.[1];

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-10-20T15:00:00Z"));
  rpc.mockReset();
  rpc.mockImplementation(async (_name: string, args: { p_semester: string; p_compare: string | null }) => ({
    data: nsmFixture(args.p_semester ?? "2026-S2", args.p_compare ?? "2025-S2"),
    error: null,
  }));
});
afterEach(() => { cleanup(); vi.useRealTimers(); });

describe("semestres", () => {
  it("deriva o semestre corrente em America/Sao_Paulo e o adjacente S1↔S2", () => {
    expect(currentSemester(new Date("2026-10-20T15:00:00Z"))).toBe("2026-S2");
    // 01/07 00:30 BRT = 03:30Z; 30/06 23:30 BRT = 01/07 02:30Z
    expect(currentSemester(new Date("2026-07-01T02:30:00Z"))).toBe("2026-S1");
    expect(currentSemester(new Date("2026-07-01T03:30:00Z"))).toBe("2026-S2");
    expect(adjacentSemester("2026-S2")).toBe("2026-S1");
    expect(adjacentSemester("2026-S1")).toBe("2025-S2");
  });
});

describe("NsmCard", () => {
  it("chama a NSM do semestre corrente comparando, por padrão, com o mesmo semestre do ano anterior", async () => {
    renderCard();
    expect(await screen.findByRole("heading", { name: /Encaminhamentos por aluno ativo/ })).toHaveTextContent("2026-S2");
    const cmp = await screen.findByRole("group", { name: "Comparação" });
    expect(rpc).toHaveBeenCalledWith("get_command_center_nsm", { p_semester: "2026-S2", p_compare: null });
    expect(within(cmp).getByText(/2025-S2/)).toBeInTheDocument();
    expect(screen.queryByText("S1 tem SiSU+ProUni; S2 só ProUni")).not.toBeInTheDocument();
  });

  it("numerador = três caminhos atuais com a composição ao lado; legado v0 fica fora, em linha própria", async () => {
    renderCard();
    const value = await screen.findByTestId("nsm-value");
    expect(value).toHaveTextContent("0,42");
    const comp = screen.getByRole("list", { name: "Composição do numerador" });
    expect(within(comp).getAllByRole("listitem")).toHaveLength(3);
    expect(within(comp).getByText(/MEC redirect/).closest("li")).toHaveTextContent("12");
    expect(within(comp).getByText(/Parceiro redirecionada/).closest("li")).toHaveTextContent("25");
    expect(within(comp).getByText(/Parceiro submetida/).closest("li")).toHaveTextContent("5");
    expect(screen.getByTestId("nsm-referrals")).toHaveTextContent("42");
    const legacy = screen.getByTestId("nsm-legacy");
    expect(legacy).toHaveTextContent("9");
    expect(legacy).toHaveTextContent(/fora do numerador/);
    // 42 + 9 nunca aparece como total
    expect(screen.queryByText("51")).not.toBeInTheDocument();
  });

  it("denominador = ativos deduplicados, nunca soma de captura diária + fontes vivas", async () => {
    renderCard();
    const den = await screen.findByTestId("nsm-active");
    expect(den).toHaveTextContent("100");
    expect(screen.queryByText("130")).not.toBeInTheDocument();
    expect(den).toHaveTextContent(/deduplicados/);
  });

  it("taxa NULL aparece como indisponível com a razão, nunca como zero", async () => {
    rpc.mockResolvedValue({
      data: nsmFixture("2026-S2", "2025-S2", {
        active_users: 0,
        active_users_source: { activity_days: 0, live_fallback: 0, deduplicated_total: 0 },
        per_active_user: null,
        coverage: { ...nsmFixture().coverage, reason: "zero_denominator" },
      }),
      error: null,
    });
    renderCard();
    const value = await screen.findByTestId("nsm-value");
    expect(value).toHaveTextContent("Indisponível");
    expect(value).not.toHaveTextContent(/^0/);
    expect(screen.getByText(/sem alunos ativos no semestre/)).toBeInTheDocument();
    // comparação com cobertura MEC incompleta também não vira zero
    const cmp = screen.getByRole("group", { name: "Comparação" });
    expect(within(cmp).getByText(/Indisponível/)).toBeInTheDocument();
    expect(within(cmp).getByText(/cobertura do redirect MEC incompleta/)).toBeInTheDocument();
  });

  it("comparar S1↔S2 pede o semestre adjacente e mostra a nota de sazonalidade", async () => {
    renderCard();
    await screen.findByTestId("nsm-value");
    fireEvent.change(screen.getByLabelText("Comparar com"), { target: { value: "adjacent" } });
    expect(await screen.findByText("S1 tem SiSU+ProUni; S2 só ProUni")).toBeInTheDocument();
    expect(lastArgs()).toEqual({ p_semester: "2026-S2", p_compare: "2026-S1" });
  });

  it("trocar o semestre refaz a consulta", async () => {
    renderCard();
    await screen.findByTestId("nsm-value");
    fireEvent.change(screen.getByLabelText("Semestre"), { target: { value: "2026-S1" } });
    expect(await screen.findByRole("heading", { name: /2026-S1/ })).toBeInTheDocument();
    expect(lastArgs()).toEqual({ p_semester: "2026-S1", p_compare: null });
  });

  it("aplica o recorte first-touch na RPC", async () => {
    renderCard({ campaignId: CAMPAIGN });
    await screen.findByTestId("nsm-value");
    expect(lastArgs()).toEqual({
      p_semester: "2026-S2", p_compare: null,
      p_filter_campaign_id: CAMPAIGN, p_filter_channel_id: null, p_filter_unattributed: null,
    });
  });

  it("declara coberturas: captura diária + fontes vivas, desde quando cada fonte é medida e o proxy histórico", async () => {
    renderCard();
    await screen.findByTestId("nsm-value");
    const cov = screen.getByRole("region", { name: "Cobertura da NSM" });
    expect(within(cov).getByText(/Sessão: primeiro registro observado em 17\/01\/2026/)).toBeInTheDocument();
    expect(within(cov).getByText(/Captura diária desde 19\/10\/2026/)).toBeInTheDocument();
    expect(within(cov).getByText(/Sessões removidas entre coletas/)).toBeInTheDocument();
    expect(within(cov).getByText(/Redirect MEC: instrumentado desde 01\/10\/2026/)).toBeInTheDocument();
    expect(within(cov).getByText(/26 candidaturas históricas datadas pelo início \(created_at\)/)).toBeInTheDocument();
  });

  it("estado de erro em PT-BR", async () => {
    rpc.mockResolvedValue({ data: null, error: new Error("denied") });
    renderCard();
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível carregar a NSM");
  });
});
