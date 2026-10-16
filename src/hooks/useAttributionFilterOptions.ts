import { useQuery } from "@tanstack/react-query";
import { getAllCampaigns, getChannels } from "@/services/channelsService";
import type { AttributionFilterOptions } from "@/lib/attributionFilter";

// Opções dos seletores de campanha/divulgador. Inclui campanhas inativas e
// divulgadores arquivados: o recorte é histórico (first-touch), e quem chegou
// por uma campanha encerrada continua sendo dela.
export const ATTRIBUTION_FILTER_OPTIONS_KEY = ["attribution-filter-options"] as const;

export function useAttributionFilterOptions() {
    const query = useQuery({
        queryKey: ATTRIBUTION_FILTER_OPTIONS_KEY,
        queryFn: async (): Promise<AttributionFilterOptions> => {
            const [campaigns, channels] = await Promise.all([getAllCampaigns(), getChannels(true)]);
            return {
                campaigns: campaigns.map((c) => ({ id: c.id, name: c.name })),
                channels: channels.map((c) => ({ id: c.id, name: c.name })),
            };
        },
        staleTime: 5 * 60 * 1000,
    });

    return {
        options: query.data ?? { campaigns: [], channels: [] },
        isLoading: query.isLoading,
        error: query.error,
    };
}
