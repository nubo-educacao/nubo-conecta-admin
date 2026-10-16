// Recorte por campanha/divulgador (first-touch) no Command Center.
//
// Mesmo filtro de Estudantes/Inscrições (src/lib/attributionFilter.ts). Aqui
// ficam só as formas de transporte do Command Center: o corpo das Edge
// Functions (analytics-stats/-activity/-rankings), a chave de cache e o
// argumento extra dos hooks. Sem filtro ativo, nada disso altera a chamada:
// corpo e args ficam idênticos aos de antes.
import {
    hasAttributionFilter,
    toAttributionRpcParams,
    type AttributionFilter,
    type AttributionRpcParams,
} from "@/lib/attributionFilter";

export interface AttributionEdgeBody {
    campaignId?: string;
    channelId?: string;
    unattributed?: true;
}

/** Campos para spread no corpo das Edge Functions. Sem filtro → `{}`. */
export function attributionEdgeBody(f?: AttributionFilter): AttributionEdgeBody {
    if (!f || !hasAttributionFilter(f)) return {};
    // "Sem atribuição" é exclusivo: nunca viaja com campanha/divulgador (a Edge recusa com 400).
    if (f.unattributed === true) return { unattributed: true };
    return {
        ...(f.campaignId && { campaignId: f.campaignId }),
        ...(f.channelId && { channelId: f.channelId }),
    };
}

/** Último elemento das query keys: os parâmetros normalizados, ou null sem filtro. */
export function attributionQueryKey(f?: AttributionFilter): AttributionRpcParams | null {
    return f && hasAttributionFilter(f) ? toAttributionRpcParams(f) : null;
}

/**
 * `[filtro]` só quando ativo — para spread na chamada de hooks/fetchers, de modo
 * que sem filtro a chamada continue com a mesma aridade de antes.
 */
export function attributionArg(f?: AttributionFilter): [] | [AttributionFilter] {
    return f && hasAttributionFilter(f) ? [f] : [];
}
