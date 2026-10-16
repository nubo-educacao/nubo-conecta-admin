// Filtro compartilhado de campanha/divulgador (TP-7 / NHB-123b).
//
// Contrato (artefato Snaps 46d78fd5, confirmado pelo PO em 15/10/2026):
// a pessoa pertence à campanha/divulgador da sua AQUISIÇÃO FIRST-TOUCH —
// user_attribution.first_touch_link_id → channel_links.(campaign_id, channel_id).
// Último toque não entra. Mesmo critério de get_channel_performance.
//
// Os três parâmetros abaixo têm o mesmo nome e a mesma semântica em todas as
// RPCs que aceitam o recorte (Estudantes, stats, Inscrições). Todos NULL =
// comportamento anterior, sem nenhuma diferença de resultado ou de ordenação.

export interface AttributionFilter {
    campaignId?: string;
    channelId?: string;
    /** Só quem não tem first-touch registrado. Exclusivo com campanha/divulgador. */
    unattributed?: boolean;
}

export interface AttributionRpcParams {
    p_filter_campaign_id: string | null;
    p_filter_channel_id: string | null;
    p_filter_unattributed: boolean | null;
}

export interface AttributionOption {
    id: string;
    name: string;
}

export interface AttributionFilterOptions {
    campaigns: AttributionOption[];
    channels: AttributionOption[];
}

/** Valor do item "Sem atribuição" no seletor de campanha. */
export const UNATTRIBUTED_VALUE = "__unattributed__";
export const UNATTRIBUTED_LABEL = "Sem atribuição";
const ALL_VALUE = "all";

export function hasAttributionFilter(f: AttributionFilter): boolean {
    return f.unattributed === true || Boolean(f.campaignId) || Boolean(f.channelId);
}

export function toAttributionRpcParams(f: AttributionFilter): AttributionRpcParams {
    // A RPC recusa (22023) "sem atribuição" combinado com campanha/divulgador.
    // A UI já torna as opções exclusivas; aqui garantimos que nunca viajam juntas.
    if (f.unattributed === true) {
        return { p_filter_campaign_id: null, p_filter_channel_id: null, p_filter_unattributed: true };
    }
    return {
        p_filter_campaign_id: f.campaignId || null,
        p_filter_channel_id: f.channelId || null,
        p_filter_unattributed: null,
    };
}

/**
 * Argumentos para spread na chamada da RPC. Sem filtro ativo devolve `{}`:
 * a chamada fica idêntica à de antes da migration e funciona com a assinatura
 * antiga ou nova — front e banco podem ser publicados em qualquer ordem.
 */
export function attributionRpcArgs(f: AttributionFilter): Partial<AttributionRpcParams> {
    return hasAttributionFilter(f) ? toAttributionRpcParams(f) : {};
}

/**
 * Próximo estado do filtro após o usuário mexer em um dos dois seletores.
 * "Sem atribuição" mora no seletor de campanha e limpa o divulgador.
 */
export function applyAttributionChange(
    current: AttributionFilter,
    field: "campaign" | "channel",
    value: string,
): AttributionFilter {
    if (field === "campaign") {
        if (value === UNATTRIBUTED_VALUE) {
            return { campaignId: undefined, channelId: undefined, unattributed: true };
        }
        return {
            campaignId: value === ALL_VALUE ? undefined : value,
            channelId: current.unattributed ? undefined : current.channelId,
            unattributed: undefined,
        };
    }
    return {
        campaignId: current.campaignId,
        channelId: value === ALL_VALUE ? undefined : value,
        unattributed: undefined,
    };
}

/** Rótulos legíveis para o resumo da exportação. */
export function describeAttributionFilter(
    f: AttributionFilter,
    options: AttributionFilterOptions,
): { campaign: string; channel: string } {
    if (f.unattributed === true) {
        return { campaign: UNATTRIBUTED_LABEL, channel: UNATTRIBUTED_LABEL };
    }
    const name = (list: AttributionOption[], id?: string) =>
        id ? list.find((o) => o.id === id)?.name ?? id : "-";
    return {
        campaign: name(options.campaigns, f.campaignId),
        channel: name(options.channels, f.channelId),
    };
}

/** Leitura/escrita na URL — mesmas chaves em todas as telas que usam o filtro. */
export function readAttributionParams(params: URLSearchParams): AttributionFilter {
    const out: AttributionFilter = {};
    if (params.get("unattributed") === "true") {
        out.unattributed = true;
        return out;
    }
    const campaignId = params.get("campaignId");
    if (campaignId) out.campaignId = campaignId;
    const channelId = params.get("channelId");
    if (channelId) out.channelId = channelId;
    return out;
}

export function writeAttributionParams(params: URLSearchParams, f: AttributionFilter): void {
    if (f.unattributed === true) {
        params.set("unattributed", "true");
        return;
    }
    if (f.campaignId) params.set("campaignId", f.campaignId);
    if (f.channelId) params.set("channelId", f.channelId);
}
