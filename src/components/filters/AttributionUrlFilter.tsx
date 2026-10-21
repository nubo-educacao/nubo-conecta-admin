import { useCallback, useMemo } from "react";
import { useSearchParams } from "react-router-dom";
import { AttributionFilterFields } from "@/components/filters/AttributionFilterFields";
import { useAttributionFilterOptions } from "@/hooks/useAttributionFilterOptions";
import {
    readAttributionParams,
    writeAttributionParams,
    type AttributionFilter,
} from "@/lib/attributionFilter";

// Recorte first-touch persistido na URL, com as mesmas chaves de Estudantes,
// Inscrições e Command Center — o link fica compartilhável entre as telas.
// Composição dos helpers compartilhados; o DashboardHeader (TP-C) tem a sua.

const ATTRIBUTION_KEYS = ["campaignId", "channelId", "unattributed"] as const;

export function useAttributionUrlState(): [AttributionFilter, (next: AttributionFilter) => void] {
    const [searchParams, setSearchParams] = useSearchParams();
    const attribution = useMemo(() => readAttributionParams(searchParams), [searchParams]);
    const setAttribution = useCallback((next: AttributionFilter) => {
        const params = new URLSearchParams(searchParams);
        ATTRIBUTION_KEYS.forEach((k) => params.delete(k));
        writeAttributionParams(params, next);
        setSearchParams(params, { replace: true });
    }, [searchParams, setSearchParams]);
    return [attribution, setAttribution];
}

interface AttributionUrlFilterProps {
    value: AttributionFilter;
    onChange: (next: AttributionFilter) => void;
}

export function AttributionUrlFilter({ value, onChange }: AttributionUrlFilterProps) {
    const { options, isLoading } = useAttributionFilterOptions();
    return (
        <div className="grid grid-cols-2 gap-3 md:max-w-xl">
            <AttributionFilterFields value={value} onChange={onChange} options={options} isLoading={isLoading} />
        </div>
    );
}
