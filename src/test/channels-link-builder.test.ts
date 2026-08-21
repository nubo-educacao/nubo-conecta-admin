import { describe, it, expect, vi } from "vitest";

// O módulo importa o client do Supabase no topo, e instanciá-lo exige env vars
// que não existem no ambiente de teste. As funções exercitadas aqui são puras —
// o mock só evita o efeito colateral do import.
vi.mock("@/integrations/supabase/client", () => ({
    supabase: { from: vi.fn(), rpc: vi.fn() },
}));

import {
    buildLinkCode,
    buildShareUrl,
    deriveUtms,
    slugify,
} from "@/services/channelsService";

// TP-7 7D — a derivação de UTM é o coração da governança de canal.
// Se ela puder ser contornada, a tela vira um formulário bonito sobre o mesmo
// problema que existe hoje.

describe("slugify", () => {
    it("remove acento sem perder a letra", () => {
        expect(slugify("Fundação 1Bi")).toBe("fundacao-1bi");
        expect(slugify("Instituição Parceira")).toBe("instituicao-parceira");
    });

    it("transforma a data digitada em separador, sem inventar formato", () => {
        // "Disparo Ponte e Sol 09/03" -> a data continua existindo em created_at;
        // o slug não precisa carregá-la.
        expect(slugify("Disparo Ponte e Sol 09/03")).toBe("disparo-ponte-e-sol-09-03");
    });

    it("não deixa separador solto nas pontas", () => {
        expect(slugify("  --Insper--  ")).toBe("insper");
        expect(slugify("!!!")).toBe("");
    });

    it("limita o tamanho", () => {
        expect(slugify("a".repeat(120)).length).toBe(60);
    });
});

describe("derivação de UTM", () => {
    const base = {
        campaignSlug: "bolsa-insper-2026",
        channelSlug: "dudinha",
        channelType: "influencer",
        platformSlug: "instagram",
    };

    it("segue a convenção validada com o marketing", () => {
        // Canal (categoria) = derivado da plataforma, nunca digitado
        // Source = plataforma · Medium = tipo do canal · Identifier = divulgador
        expect(deriveUtms(base)).toEqual({
            utm_source: "instagram",
            utm_medium: "influencer",
            utm_campaign: "bolsa-insper-2026",
            utm_content: "dudinha",
            utm_term: null,
        });
    });

    it("o medium vem do TIPO do canal, não de digitação", () => {
        // É o que impede um disparo de CRM ser cadastrado como influencer —
        // exatamente o que aconteceu com os 82 registros legados.
        expect(deriveUtms({ ...base, channelType: "crm" }).utm_medium).toBe("crm");
    });

    it("sem plataforma, o source é explícito e não vazio", () => {
        // String vazia em utm_source é o que produz "Não definido" no relatório.
        expect(deriveUtms({ ...base, platformSlug: null }).utm_source).toBe("direct");
    });

    it("aceita link sem campanha, mas registra a ausência", () => {
        expect(deriveUtms({ ...base, campaignSlug: null }).utm_campaign).toBeNull();
    });
});

describe("código do link", () => {
    it("é legível — quem vê numa planilha entende sem consultar o banco", () => {
        expect(buildLinkCode("bolsa-insper-2026", "dudinha", "instagram")).toBe(
            "bolsa-insper-2026-dudinha-instagram",
        );
    });

    it("omite as partes ausentes sem deixar separador duplo", () => {
        expect(buildLinkCode(null, "dudinha", "instagram")).toBe("dudinha-instagram");
        expect(buildLinkCode(null, "dudinha", null)).toBe("dudinha");
    });

    it("gera URL no domínio correto", () => {
        // O bug NHB-69 era exatamente isto: .com.br em vez de .org.br.
        expect(buildShareUrl("dudinha")).toBe(
            "https://conecta.nuboeducacao.org.br/r/dudinha",
        );
    });
});
