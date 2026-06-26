import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { listPartnerOpportunities } from "@/services/partnerOpportunitiesService";
import { PartnerFormsManager } from "@/components/partners/PartnerFormsManager";

export default function PartnerForms() {
    const { data: opportunitiesResult, isLoading } = useQuery({
        queryKey: ["partner-opportunities-all"],
        queryFn: () => listPartnerOpportunities({ limit: 100 }),
    });

    const opportunities = opportunitiesResult?.data ?? [];
    const isInitialLoading = isLoading && opportunities.length === 0;

    if (isInitialLoading) {
        return (
            <div className="flex h-[400px] items-center justify-center">
                <Loader2 className="h-8 w-8 animate-spin text-primary" />
            </div>
        );
    }

    return (
        <div className="container mx-auto space-y-8 p-6">
            <div>
                <h1 className="text-3xl font-bold tracking-tight">Formulários de Elegibilidade</h1>
                <p className="text-muted-foreground">
                    Configure os campos e critérios para o Passaporte de cada oportunidade parceira.
                </p>
            </div>

            <PartnerFormsManager opportunities={opportunities} />
        </div>
    );
}
