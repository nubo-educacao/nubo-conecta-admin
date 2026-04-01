import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import {
    getPartnerSolicitations,
    PartnerSolicitation,
} from "@/services/partnerSolicitationsService";
import { PartnerSolicitationsTable } from "@/components/partners/PartnerSolicitationsTable";
import { PartnerSolicitationDialog } from "@/components/partners/PartnerSolicitationDialog";

export default function PartnerSolicitations() {
    const [selectedSolicitation, setSelectedSolicitation] = useState<PartnerSolicitation | null>(null);
    const [isSolicitationDialogOpen, setIsSolicitationDialogOpen] = useState(false);

    const { data: solicitations = [], isLoading } = useQuery({
        queryKey: ["partner-solicitations"],
        queryFn: getPartnerSolicitations,
    });

    const handleViewSolicitation = (solicitation: PartnerSolicitation) => {
        setSelectedSolicitation(solicitation);
        setIsSolicitationDialogOpen(true);
    };

    if (isLoading) {
        return (
            <div className="flex h-[400px] items-center justify-center">
                <Loader2 className="h-8 w-8 animate-spin text-primary" />
            </div>
        );
    }

    return (
        <div className="container mx-auto space-y-8 p-6">
            <div>
                <h1 className="text-3xl font-bold tracking-tight">Solicitações de Parceria</h1>
                <p className="text-muted-foreground">
                    Analise e gerencie as solicitações recebidas.
                </p>
            </div>

            <div className="space-y-4">
                <PartnerSolicitationsTable
                    solicitations={solicitations}
                    onView={handleViewSolicitation}
                />
            </div>

            <PartnerSolicitationDialog
                isOpen={isSolicitationDialogOpen}
                onOpenChange={setIsSolicitationDialogOpen}
                solicitation={selectedSolicitation}
            />
        </div>
    );
}
