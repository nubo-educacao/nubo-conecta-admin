import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { X } from "lucide-react";

export interface PartnerOpportunityOption {
    id: string;
    name: string;
}

interface PartnerOpportunityMultiSelectProps {
    options: PartnerOpportunityOption[];
    selectedIds: string[];
    onChange: (ids: string[]) => void;
}

export default function PartnerOpportunityMultiSelect({
    options,
    selectedIds,
    onChange,
}: PartnerOpportunityMultiSelectProps) {
    const selectedOptions = options.filter((o) => selectedIds.includes(o.id));

    const toggle = (id: string) => {
        if (selectedIds.includes(id)) {
            onChange(selectedIds.filter((sid) => sid !== id));
        } else {
            onChange([...selectedIds, id]);
        }
    };

    const remove = (id: string) => {
        onChange(selectedIds.filter((sid) => sid !== id));
    };

    return (
        <div className="space-y-2">
            {selectedOptions.length > 0 ? (
                <div className="flex flex-wrap gap-1">
                    {selectedOptions.map((o) => (
                        <Badge key={o.id} variant="secondary" className="gap-1">
                            {o.name}
                            <button
                                type="button"
                                aria-label={`Remover ${o.name}`}
                                onClick={() => remove(o.id)}
                                className="ml-1 hover:text-destructive"
                            >
                                <X className="h-3 w-3" />
                            </button>
                        </Badge>
                    ))}
                </div>
            ) : (
                <p className="text-sm text-muted-foreground">Nenhuma selecionada</p>
            )}

            <div className="max-h-40 overflow-y-auto rounded-md border p-2 space-y-1">
                {options.map((o) => {
                    const checkboxId = `partner-opportunity-${o.id}`;
                    return (
                        <div key={o.id} className="flex items-center gap-2">
                            <Checkbox
                                id={checkboxId}
                                aria-label={o.name}
                                checked={selectedIds.includes(o.id)}
                                onCheckedChange={() => toggle(o.id)}
                            />
                            <Label htmlFor={checkboxId} className="font-normal cursor-pointer">
                                {o.name}
                            </Label>
                        </div>
                    );
                })}
            </div>
        </div>
    );
}
