import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { getPartners } from "@/services/partnersService";
import { PartnerUsersManager } from "@/components/partners/PartnerUsersManager";

export default function PartnerUsers() {
    const { data: partners = [], isLoading } = useQuery({
        queryKey: ["partners", "name", "asc"],
        queryFn: () => getPartners("name", "asc"),
    });

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
                <h1 className="text-3xl font-bold tracking-tight">Usuários de Parceiros</h1>
                <p className="text-muted-foreground">
                    Gerencie os acessos ao Portal do Parceiro.
                </p>
            </div>

            <PartnerUsersManager partners={partners} />
        </div>
    );
}
