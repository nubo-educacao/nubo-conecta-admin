import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Plus, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { PartnerStats } from "@/components/partners/PartnerStats";
import { PartnerTable } from "@/components/partners/PartnerTable";
import { PartnerDialog } from "@/components/partners/PartnerDialog";
import {
    getPartners,
    getPartnerStatistics,
    createPartner,
    updatePartner,
    deletePartner,
    Partner,
} from "@/services/partnersService";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";

export default function Partners() {
    const queryClient = useQueryClient();
    const [isDialogOpen, setIsDialogOpen] = useState(false);
    const [selectedPartner, setSelectedPartner] = useState<Partner | undefined>();

    // Sorting state
    const [sortBy, setSortBy] = useState("name");
    const [sortOrder, setSortOrder] = useState("asc");

    // Queries
    const { data: partners = [], isLoading: isLoadingPartners } = useQuery({
        queryKey: ["partners", sortBy, sortOrder],
        queryFn: () => getPartners(sortBy, sortOrder),
    });

    const { data: stats, isLoading: isLoadingStats } = useQuery({
        queryKey: ["partner-stats"],
        queryFn: getPartnerStatistics,
    });

    const handleSort = (field: string) => {
        if (sortBy === field) {
            setSortOrder(sortOrder === "asc" ? "desc" : "asc");
        } else {
            setSortBy(field);
            setSortOrder("asc");
        }
    };

    const { data: clicksMap = {} } = useQuery({
        queryKey: ["partners-clicks-map"],
        queryFn: async () => {
            const { data, error } = await supabase
                .from("partners_click")
                .select("partner_id, clicks");

            if (error) throw error;

            const map: Record<string, number> = {};
            data.forEach(item => {
                map[item.partner_id] = (map[item.partner_id] || 0) + item.clicks;
            });
            return map;
        }
    });

    // Mutations
    const createMutation = useMutation({
        mutationFn: createPartner,
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partners"] });
            queryClient.invalidateQueries({ queryKey: ["partner-stats"] });
            toast.success("Parceiro criado com sucesso!");
        },
        onError: () => toast.error("Erro ao criar parceiro."),
    });

    const updateMutation = useMutation({
        mutationFn: ({ id, data }: { id: string; data: any }) => updatePartner(id, data),
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partners"] });
            queryClient.invalidateQueries({ queryKey: ["partner-stats"] });
            toast.success("Parceiro atualizado com sucesso!");
        },
        onError: () => toast.error("Erro ao atualizar parceiro."),
    });

    const deleteMutation = useMutation({
        mutationFn: (id: string) => deletePartner(id),
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partners"] });
            queryClient.invalidateQueries({ queryKey: ["partner-stats"] });
            toast.success("Parceiro removido com sucesso!");
        },
        onError: () => toast.error("Erro ao remover parceiro."),
    });

    const handleAddPartner = () => {
        setSelectedPartner(undefined);
        setIsDialogOpen(true);
    };

    const handleEditPartner = (partner: Partner) => {
        setSelectedPartner(partner);
        setIsDialogOpen(true);
    };

    const handleSubmit = async (values: any) => {
        if (selectedPartner) {
            await updateMutation.mutateAsync({ id: selectedPartner.id, data: values });
        } else {
            await createMutation.mutateAsync(values);
        }
    };

    if (isLoadingPartners || isLoadingStats) {
        return (
            <div className="flex h-[400px] items-center justify-center">
                <Loader2 className="h-8 w-8 animate-spin text-primary" />
            </div>
        );
    }

    return (
        <div className="container mx-auto space-y-8 p-6">
            <div className="flex items-center justify-between">
                <div>
                    <h1 className="text-3xl font-bold tracking-tight">Parceiros</h1>
                    <p className="text-muted-foreground">
                        Gerencie os parceiros e acompanhe o desempenho de cliques.
                    </p>
                </div>
                <Button onClick={handleAddPartner} className="gap-2">
                    <Plus className="h-4 w-4" />
                    Novo Parceiro
                </Button>
            </div>

            <div className="space-y-4">
                {stats && <PartnerStats stats={stats} />}

                <div className="space-y-4">
                    <h2 className="text-xl font-semibold">Listagem de Parceiros</h2>
                    <PartnerTable
                        partners={partners}
                        clicksMap={clicksMap}
                        onEdit={handleEditPartner}
                        sortBy={sortBy}
                        sortOrder={sortOrder}
                        onSort={handleSort}
                    />
                </div>
            </div>

            <PartnerDialog
                isOpen={isDialogOpen}
                onOpenChange={setIsDialogOpen}
                partner={selectedPartner}
                onSubmit={handleSubmit}
                onDelete={selectedPartner ? async () => {
                    await deleteMutation.mutateAsync(selectedPartner.id);
                } : undefined}
            />
        </div>
    );
}

