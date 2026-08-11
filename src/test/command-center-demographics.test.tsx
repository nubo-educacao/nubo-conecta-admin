import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MatchHealthChart } from "@/components/analytics/MatchHealthChart";
import { DemographicsCharts } from "@/components/analytics/DemographicsCharts";
import {
    fetchCommandCenterDemographics,
    type CommandCenterDemographics,
} from "@/lib/analytics-queries";
import { supabase } from "@/integrations/supabase/client";

vi.mock("@/integrations/supabase/client", () => ({
    supabase: { rpc: vi.fn() },
}));

const rpc = vi.mocked(supabase.rpc);

const payload: CommandCenterDemographics = {
    match_health: { with_match: 2, without_match: 3, total: 5 },
    education: [
        { label: "medio", value: 3 },
        { label: "superior", value: 1 },
        { label: "Não respondeu", value: 1 },
    ],
    income: [
        { label: "Até R$ 500", value: 1 },
        { label: "Não respondeu", value: 4 },
    ],
    race: [
        { label: "parda", value: 2 },
        { label: "Não respondeu", value: 3 },
    ],
    school_type: [
        { label: "publica", value: 3 },
        { label: "Não respondeu", value: 2 },
    ],
};

// QueryClient novo por render: client compartilhado no describe vaza cache
// entre testes e o segundo teste passa a ler o resultado do primeiro.
function renderWithClient(ui: React.ReactElement) {
    const client = new QueryClient({
        defaultOptions: { queries: { retry: false, gcTime: 0 } },
    });
    return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>);
}

beforeEach(() => {
    rpc.mockReset();
    rpc.mockResolvedValue({ data: payload, error: null } as never);
});

describe("fetchCommandCenterDemographics", () => {
    it("chama a RPC agregadora única, não uma query por dimensão", async () => {
        await fetchCommandCenterDemographics();

        expect(rpc).toHaveBeenCalledTimes(1);
        expect(rpc).toHaveBeenCalledWith("get_command_center_demographics");
    });

    it("propaga o erro de autorização em vez de devolver dados vazios", async () => {
        rpc.mockResolvedValue({
            data: null,
            error: { code: "42501", message: "acesso restrito ao backoffice" },
        } as never);

        await expect(fetchCommandCenterDemographics()).rejects.toMatchObject({ code: "42501" });
    });
});

describe("MatchHealthChart", () => {
    it("mostra a proporção de usuários com match", async () => {
        renderWithClient(<MatchHealthChart />);

        // 2 de 5 = 40%
        expect(await screen.findByText(/40% dos 5 usuários/)).toBeInTheDocument();
    });

    it("não quebra quando não há usuário nenhum", async () => {
        rpc.mockResolvedValue({
            data: { ...payload, match_health: { with_match: 0, without_match: 0, total: 0 } },
            error: null,
        } as never);

        renderWithClient(<MatchHealthChart />);

        expect(await screen.findByText(/Nenhum usuário cadastrado/)).toBeInTheDocument();
    });

    it("exibe estado de erro quando a RPC falha", async () => {
        rpc.mockResolvedValue({ data: null, error: { message: "boom" } } as never);

        renderWithClient(<MatchHealthChart />);

        expect(await screen.findByText(/Não foi possível carregar a saúde do match/)).toBeInTheDocument();
    });
});

describe("DemographicsCharts", () => {
    it("renderiza as 4 dimensões", async () => {
        renderWithClient(<DemographicsCharts />);

        expect(await screen.findByText("Escolaridade")).toBeInTheDocument();
        expect(screen.getByText("Renda per capita")).toBeInTheDocument();
        expect(screen.getByText("Raça/cor")).toBeInTheDocument();
        expect(screen.getByText("Tipo de escola")).toBeInTheDocument();
    });

    it("mostra a cobertura de preenchimento por dimensão", async () => {
        renderWithClient(<DemographicsCharts />);

        // Escolaridade: 4 de 5 responderam = 80%
        expect(await screen.findByText(/80% preencheram/)).toBeInTheDocument();
        // Renda: 1 de 5 = 20%. Sem o bucket "Não respondeu" o gráfico pareceria completo.
        expect(screen.getByText(/20% preencheram/)).toBeInTheDocument();
    });
});
