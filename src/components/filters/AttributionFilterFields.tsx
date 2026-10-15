import { Label } from "@/components/ui/label";
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import {
    applyAttributionChange,
    UNATTRIBUTED_LABEL,
    UNATTRIBUTED_VALUE,
    type AttributionFilter,
    type AttributionFilterOptions,
} from "@/lib/attributionFilter";

// Seletores de campanha/divulgador compartilhados por Estudantes, Inscrições e
// Command Center (TP-7 / NHB-123b). Componente "burro": quem usa decide de onde
// vêm as opções (useAttributionFilterOptions) e onde o valor é guardado.

interface AttributionFilterFieldsProps {
    value: AttributionFilter;
    onChange: (next: AttributionFilter) => void;
    options: AttributionFilterOptions;
    isLoading?: boolean;
}

export function AttributionFilterFields({ value, onChange, options, isLoading }: AttributionFilterFieldsProps) {
    const campaignValue = value.unattributed ? UNATTRIBUTED_VALUE : value.campaignId ?? "all";
    const channelValue = value.channelId ?? "all";

    return (
        <>
            <div className="grid gap-2">
                <Label htmlFor="attribution-campaign">Campanha</Label>
                <Select
                    value={campaignValue}
                    disabled={isLoading}
                    onValueChange={(v) => onChange(applyAttributionChange(value, "campaign", v))}
                >
                    <SelectTrigger id="attribution-campaign" aria-label="Campanha">
                        <SelectValue placeholder="Todas" />
                    </SelectTrigger>
                    <SelectContent>
                        <SelectItem value="all">Todas</SelectItem>
                        <SelectItem value={UNATTRIBUTED_VALUE}>{UNATTRIBUTED_LABEL}</SelectItem>
                        {options.campaigns.map((c) => (
                            <SelectItem key={c.id} value={c.id}>
                                {c.name}
                            </SelectItem>
                        ))}
                    </SelectContent>
                </Select>
            </div>

            <div className="grid gap-2">
                <Label htmlFor="attribution-channel">Divulgador</Label>
                <Select
                    value={channelValue}
                    disabled={isLoading || value.unattributed === true}
                    onValueChange={(v) => onChange(applyAttributionChange(value, "channel", v))}
                >
                    <SelectTrigger id="attribution-channel" aria-label="Divulgador">
                        <SelectValue placeholder="Todos" />
                    </SelectTrigger>
                    <SelectContent>
                        <SelectItem value="all">Todos</SelectItem>
                        {options.channels.map((c) => (
                            <SelectItem key={c.id} value={c.id}>
                                {c.name}
                            </SelectItem>
                        ))}
                    </SelectContent>
                </Select>
            </div>

            <p className="col-span-2 text-xs text-muted-foreground">
                Campanha e divulgador consideram o primeiro link pelo qual a pessoa chegou (first-touch).
            </p>
        </>
    );
}
