// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import React from "react";
import { render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { ActivityChart, activityXAxisInterval } from "./ActivityChart";

vi.mock("@/integrations/supabase/client", () => ({
    supabase: { functions: { invoke: vi.fn() } },
}));

const ninetyDays = Array.from({ length: 90 }, (_, i) => ({ label: `${i + 1}/10`, mensagens: i % 3, usuarios: 1 }));

function renderChart() {
    vi.mocked(supabase.functions.invoke).mockResolvedValue({ data: ninetyDays, error: null } as never);
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    return render(
        <QueryClientProvider client={client}>
            <ActivityChart dateRange={{ from: new Date("2026-07-18"), to: new Date("2026-10-16") }} />
        </QueryClientProvider>,
    );
}

describe("ActivityChart — eixo e seletor de modo", () => {
    it("não força um rótulo por dia no modo Por dia: o eixo escolhe rótulos que cabem", () => {
        expect(activityXAxisInterval("week", null)).toBe("preserveStartEnd");
        expect(activityXAxisInterval("total", null)).toBe("preserveStartEnd");
    });

    it("mantém Por hora a cada 3 horas e o zoom de 15 minutos com todos os rótulos", () => {
        expect(activityXAxisInterval("day", null)).toBe(2);
        expect(activityXAxisInterval("day", 14)).toBe(0);
    });

    it("o modo ativo tem cor de texto explícita sobre o fundo claro (rótulo legível)", async () => {
        renderChart();

        const ativo = await screen.findByRole("radio", { name: "Por dia" });
        expect(ativo).toHaveAttribute("data-state", "on");
        expect(ativo.className).toContain("data-[state=on]:text-foreground");
        for (const nome of ["Por hora", "Total"]) {
            expect(screen.getByRole("radio", { name: nome }).className).toContain("data-[state=on]:text-foreground");
        }
    });
});
