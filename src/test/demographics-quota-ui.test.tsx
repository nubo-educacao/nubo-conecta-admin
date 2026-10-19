import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { DemographicsCharts } from "@/components/analytics/DemographicsCharts";
import { sliceFill } from "@/components/analytics/demographicsFill";
import type { CommandCenterDemographics } from "@/lib/analytics-queries";
import { supabase } from "@/integrations/supabase/client";

vi.mock("@/integrations/supabase/client", () => ({
    supabase: { rpc: vi.fn() },
}));

const rpc = vi.mocked(supabase.rpc);

// Mesmos números da suíte SQL (src/test/demographics-quota-sql.test.ts).
const payload: CommandCenterDemographics = {
    match_health: { with_match: 0, without_match: 17, total: 17 },
    education: [{ label: "Não respondeu", value: 17 }],
    income: [{ label: "Não respondeu", value: 17 }],
    race: [
        { label: "Parda", value: 1, source: "self_declared" },
        { label: "Prefiro não informar", value: 1, source: "self_declared" },
        { label: "Preta", value: 1, source: "self_declared" },
        { label: "Indígena (por cota)", value: 2, source: "quota_inferred" },
        { label: "Pretos e pardos (por cota)", value: 2, source: "quota_inferred" },
        { label: "PPI (por cota)", value: 1, source: "quota_inferred" },
        { label: "Não respondeu", value: 9, source: "unanswered" },
    ],
    school_type: [
        { label: "Escola particular sem bolsa", value: 1, source: "self_declared" },
        { label: "Escola pública (por cota)", value: 2, source: "quota_inferred" },
        { label: "Privada com bolsa integral (por cota)", value: 2, source: "quota_inferred" },
        { label: "Não respondeu", value: 12, source: "unanswered" },
    ],
    coverage: {
        race: {
            total_users: 17, self_declared: 2, quota_inferred: 5, uncovered: 10, declined: 1,
            self_declared_pct: 11.8, quota_inferred_pct: 29.4, uncovered_pct: 58.8, covered_pct: 41.2,
        },
        school_type: {
            total_users: 17, self_declared: 1, quota_inferred: 4, uncovered: 12,
            self_declared_pct: 5.9, quota_inferred_pct: 23.5, uncovered_pct: 70.6, covered_pct: 29.4,
        },
    },
};

function renderWithClient(ui: React.ReactElement) {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
    return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>);
}

beforeEach(() => {
    rpc.mockReset();
    rpc.mockResolvedValue({ data: payload, error: null } as never);
});

describe("DemographicsCharts — inferência por cota (NUB-RD-92)", () => {
    it("mostra cobertura total e a fração de cada fonte em raça e escola", async () => {
        renderWithClient(<DemographicsCharts />);

        const race = await screen.findByTestId("coverage-race");
        expect(race).toHaveTextContent("Cobertura 41,2% · Autodeclarado 11,8% · Inferido por cota 29,4%");
        expect(screen.getByTestId("coverage-school_type")).toHaveTextContent(
            "Cobertura 29,4% · Autodeclarado 5,9% · Inferido por cota 23,5%",
        );
        // A recusa não é cobertura, mas aparece à parte.
        expect(race).toHaveTextContent("1 preferiu não informar");
    });

    it("tem legenda Autodeclarado × Inferido por cota e a nota de elegibilidade", async () => {
        renderWithClient(<DemographicsCharts />);

        const legends = await screen.findAllByTestId("provenance-legend");
        expect(legends).toHaveLength(2);
        for (const legend of legends) {
            expect(within(legend).getByText("Autodeclarado")).toBeInTheDocument();
            expect(within(legend).getByText("Inferido por cota")).toBeInTheDocument();
        }
        expect(screen.getAllByText("Cota indica elegibilidade declarada, não autodeclaração.")).toHaveLength(2);
    });

    it("sem base (total_users = 0) não inventa percentual", async () => {
        const empty = {
            total_users: 0, self_declared: 0, quota_inferred: 0, uncovered: 0,
            self_declared_pct: null, quota_inferred_pct: null, uncovered_pct: null, covered_pct: null,
        };
        rpc.mockResolvedValue({
            data: {
                ...payload,
                match_health: { with_match: 0, without_match: 0, total: 0 },
                race: [], school_type: [], education: [], income: [],
                coverage: { race: { ...empty, declined: 0 }, school_type: empty },
            } satisfies CommandCenterDemographics,
            error: null,
        } as never);

        renderWithClient(<DemographicsCharts />);

        expect(await screen.findByTestId("coverage-race")).toHaveTextContent("Sem base para calcular a cobertura");
        expect(screen.queryByText(/NaN|null/)).not.toBeInTheDocument();
    });

    it("payload antigo, sem coverage, continua com o subtítulo de preenchimento e sem legenda", async () => {
        const { coverage: _omit, ...old } = payload;
        rpc.mockResolvedValue({
            data: {
                ...old,
                race: [{ label: "Parda", value: 2 }, { label: "Não respondeu", value: 3 }],
                school_type: [{ label: "Não respondeu", value: 5 }],
            },
            error: null,
        } as never);

        renderWithClient(<DemographicsCharts />);

        expect(await screen.findByText(/40% preencheram/)).toBeInTheDocument();
        expect(screen.queryByTestId("provenance-legend")).not.toBeInTheDocument();
    });
});

describe("sliceFill", () => {
    it("diferencia inferido por cota, autodeclarado e não respondeu", () => {
        expect(sliceFill({ label: "PPI (por cota)", value: 1, source: "quota_inferred" }, 3)).toMatch(/^url\(#/);
        expect(sliceFill({ label: "Não respondeu", value: 1, source: "unanswered" }, 0)).toBe("hsl(var(--muted-foreground))");
        expect(sliceFill({ label: "Parda", value: 1, source: "self_declared" }, 0)).toBe("hsl(var(--primary))");
        // Payload antigo: sem source, só "Não respondeu" é cinza.
        expect(sliceFill({ label: "Não respondeu", value: 1 }, 0)).toBe("hsl(var(--muted-foreground))");
        expect(sliceFill({ label: "Parda", value: 1 }, 1)).toBe("hsl(var(--chart-2))");
    });
});
