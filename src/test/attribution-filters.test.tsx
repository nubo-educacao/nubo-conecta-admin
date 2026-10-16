import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import { renderHook, act } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import type { ReactNode } from "react";
import {
    applyAttributionChange,
    describeAttributionFilter,
    hasAttributionFilter,
    toAttributionRpcParams,
    UNATTRIBUTED_VALUE,
} from "@/lib/attributionFilter";
import { getStudents, getStudentStats } from "@/services/studentsService";
import { getApplicationsWithDetails } from "@/services/applicationsService";
import { useStudentFilters } from "@/hooks/useStudentFilters";
import { AttributionFilterFields } from "@/components/filters/AttributionFilterFields";
import { supabase } from "@/integrations/supabase/client";

// Contrato TP-7 / NHB-123b (artefato 46d78fd5): recorte por aquisição
// FIRST-TOUCH, confirmado pelo PO em 15/10/2026. Os três parâmetros são os
// mesmos em todas as RPCs (Estudantes, Inscrições, Command Center).

vi.mock("@/integrations/supabase/client", () => ({
    supabase: { rpc: vi.fn() },
}));

const rpc = vi.mocked(supabase.rpc);

const CAMPAIGN = "11111111-1111-1111-1111-111111111111";
const CHANNEL = "22222222-2222-2222-2222-222222222222";

beforeEach(() => {
    rpc.mockReset();
    rpc.mockResolvedValue({ data: { data: [], count: 0 }, error: null } as never);
});

describe("toAttributionRpcParams", () => {
    it("filtro vazio vira três NULL — preserva o baseline das RPCs", () => {
        expect(toAttributionRpcParams({})).toEqual({
            p_filter_campaign_id: null,
            p_filter_channel_id: null,
            p_filter_unattributed: null,
        });
    });

    it("campanha e divulgador seguem juntos (AND no mesmo link first-touch)", () => {
        expect(toAttributionRpcParams({ campaignId: CAMPAIGN, channelId: CHANNEL })).toEqual({
            p_filter_campaign_id: CAMPAIGN,
            p_filter_channel_id: CHANNEL,
            p_filter_unattributed: null,
        });
    });

    it("'Sem atribuição' nunca viaja junto com campanha/divulgador", () => {
        expect(
            toAttributionRpcParams({ campaignId: CAMPAIGN, channelId: CHANNEL, unattributed: true })
        ).toEqual({
            p_filter_campaign_id: null,
            p_filter_channel_id: null,
            p_filter_unattributed: true,
        });
    });

    it("unattributed=false é o mesmo que ausente", () => {
        expect(toAttributionRpcParams({ unattributed: false }).p_filter_unattributed).toBeNull();
        expect(hasAttributionFilter({ unattributed: false })).toBe(false);
    });
});

describe("applyAttributionChange — opções mutuamente exclusivas", () => {
    it("escolher 'Sem atribuição' limpa campanha e divulgador", () => {
        expect(
            applyAttributionChange({ campaignId: CAMPAIGN, channelId: CHANNEL }, "campaign", UNATTRIBUTED_VALUE)
        ).toEqual({ campaignId: undefined, channelId: undefined, unattributed: true });
    });

    it("escolher uma campanha sai de 'Sem atribuição'", () => {
        expect(applyAttributionChange({ unattributed: true }, "campaign", CAMPAIGN)).toEqual({
            campaignId: CAMPAIGN,
            channelId: undefined,
            unattributed: undefined,
        });
    });

    it("escolher um divulgador preserva a campanha", () => {
        expect(applyAttributionChange({ campaignId: CAMPAIGN }, "channel", CHANNEL)).toEqual({
            campaignId: CAMPAIGN,
            channelId: CHANNEL,
            unattributed: undefined,
        });
    });

    it("'all' limpa só o campo escolhido", () => {
        expect(applyAttributionChange({ campaignId: CAMPAIGN, channelId: CHANNEL }, "campaign", "all")).toEqual({
            campaignId: undefined,
            channelId: CHANNEL,
            unattributed: undefined,
        });
        expect(applyAttributionChange({ unattributed: true }, "campaign", "all")).toEqual({
            campaignId: undefined,
            channelId: undefined,
            unattributed: undefined,
        });
    });
});

describe("describeAttributionFilter — rótulos para resumo/exportação", () => {
    const options = {
        campaigns: [{ id: CAMPAIGN, name: "Insper 2026" }],
        channels: [{ id: CHANNEL, name: "Dudinha" }],
    };

    it("nomes legíveis, '-' quando ausente", () => {
        expect(describeAttributionFilter({ campaignId: CAMPAIGN }, options)).toEqual({
            campaign: "Insper 2026",
            channel: "-",
        });
    });

    it("'Sem atribuição' aparece explicitamente", () => {
        expect(describeAttributionFilter({ unattributed: true }, options)).toEqual({
            campaign: "Sem atribuição",
            channel: "Sem atribuição",
        });
    });

    it("id desconhecido não some do resumo", () => {
        expect(describeAttributionFilter({ channelId: "x" }, { campaigns: [], channels: [] }).channel).toBe(
            "x"
        );
    });
});

describe("getStudents — lista e total usam o mesmo recorte dos cards", () => {
    it("sem filtros envia exatamente a chamada de antes (sem os parâmetros novos)", async () => {
        await getStudents({ page: 0, pageSize: 20, filters: {}, sortBy: "full_name", sortOrder: "asc" });
        expect(rpc).toHaveBeenCalledWith("get_students_paginated", {
            p_page: 0,
            p_page_size: 20,
            p_filter_name: null,
            p_filter_city: null,
            p_filter_education: null,
            p_filter_is_nubo_student: null,
            p_filter_income_min: null,
            p_filter_income_max: null,
            p_filter_quota_types: null,
            p_sort_by: "full_name",
            p_sort_order: "asc",
            p_filter_state: null,
            p_filter_age_min: null,
            p_filter_age_max: null,
        });
    });

    it("nome, renda e idade da página chegam à RPC da lista (antes eram ignorados)", async () => {
        await getStudents({
            filters: { fullName: "Ana", incomeMin: 100, incomeMax: 900, ageMin: 16, ageMax: 30 },
        });
        expect(rpc).toHaveBeenCalledWith(
            "get_students_paginated",
            expect.objectContaining({
                p_filter_name: "Ana",
                p_filter_income_min: 100,
                p_filter_income_max: 900,
                p_filter_age_min: 16,
                p_filter_age_max: 30,
            })
        );
    });

    it("campanha/divulgador chegam à lista", async () => {
        await getStudents({ filters: { campaignId: CAMPAIGN, channelId: CHANNEL } });
        expect(rpc).toHaveBeenCalledWith(
            "get_students_paginated",
            expect.objectContaining({ p_filter_campaign_id: CAMPAIGN, p_filter_channel_id: CHANNEL })
        );
    });
});

describe("getStudentStats — mesmos parâmetros de atribuição da lista", () => {
    it("envia o trio de atribuição", async () => {
        rpc.mockResolvedValueOnce({ data: { total_students: 0 }, error: null } as never);
        await getStudentStats({ unattributed: true });
        expect(rpc).toHaveBeenCalledWith(
            "get_student_stats",
            expect.objectContaining({
                p_filter_campaign_id: null,
                p_filter_channel_id: null,
                p_filter_unattributed: true,
            })
        );
    });

    it("sem filtros, stats recebe só NULL", async () => {
        rpc.mockResolvedValueOnce({ data: { total_students: 0 }, error: null } as never);
        await getStudentStats({});
        const args = rpc.mock.calls[0][1] as Record<string, unknown>;
        expect(Object.values(args).every((v) => v === null)).toBe(true);
    });
});

describe("useStudentFilters — atribuição sobrevive na URL", () => {
    const wrapper =
        (initial: string) =>
        ({ children }: { children: ReactNode }) =>
            <MemoryRouter initialEntries={[initial]}>{children}</MemoryRouter>;

    it("lê campaignId/channelId da URL", () => {
        const { result } = renderHook(() => useStudentFilters("t-filters"), {
            wrapper: wrapper(`/students?campaignId=${CAMPAIGN}&channelId=${CHANNEL}`),
        });
        expect(result.current.filters).toEqual({ campaignId: CAMPAIGN, channelId: CHANNEL });
    });

    it("grava e relê 'Sem atribuição'", () => {
        const { result } = renderHook(() => useStudentFilters("t-filters-2"), { wrapper: wrapper("/students") });
        act(() => result.current.setFilters({ unattributed: true }));
        expect(result.current.filters).toEqual({ unattributed: true });
    });
});

describe("AttributionFilterFields", () => {
    it("renderiza Campanha e Divulgador", () => {
        render(
            <AttributionFilterFields
                value={{}}
                onChange={vi.fn()}
                options={{ campaigns: [], channels: [] }}
            />
        );
        expect(screen.getByText("Campanha")).toBeInTheDocument();
        expect(screen.getByText("Divulgador")).toBeInTheDocument();
    });

    it("com 'Sem atribuição' o divulgador fica desabilitado", () => {
        render(
            <AttributionFilterFields
                value={{ unattributed: true }}
                onChange={vi.fn()}
                options={{ campaigns: [], channels: [] }}
            />
        );
        expect(screen.getByRole("combobox", { name: "Divulgador" })).toBeDisabled();
    });
});

describe("getApplicationsWithDetails — Inscrições pelo first-touch do aluno", () => {
    it("sem filtro mantém a chamada atual (sem parâmetros)", async () => {
        rpc.mockResolvedValueOnce({ data: [], error: null } as never);
        await getApplicationsWithDetails();
        expect(rpc).toHaveBeenCalledWith("get_student_applications_with_details", {});
    });

    it("com campanha envia o trio do contrato", async () => {
        rpc.mockResolvedValueOnce({ data: [], error: null } as never);
        await getApplicationsWithDetails(undefined, { campaignId: CAMPAIGN });
        expect(rpc).toHaveBeenCalledWith("get_student_applications_with_details", {
            p_filter_campaign_id: CAMPAIGN,
            p_filter_channel_id: null,
            p_filter_unattributed: null,
        });
    });

    it("parceiro e atribuição combinam", async () => {
        rpc.mockResolvedValueOnce({ data: [], error: null } as never);
        await getApplicationsWithDetails("p1", { unattributed: true });
        expect(rpc).toHaveBeenCalledWith("get_student_applications_with_details", {
            p_partner_id: "p1",
            p_filter_campaign_id: null,
            p_filter_channel_id: null,
            p_filter_unattributed: true,
        });
    });
});
