import { Users, MousePointer2, Trophy, UserCheck, TrendingUp, UserPlus } from "lucide-react";
import { StatCard } from "@/components/analytics/StatCard";
import { PartnerStats as PartnerStatsType } from "@/services/partnersService";

interface PartnerStatsProps {
    stats: PartnerStatsType;
}

export function PartnerStats({ stats }: PartnerStatsProps) {
    return (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
            <StatCard
                title="Total de Parceiros"
                value={stats.totalPartners}
                icon={Users}
                variant="default"
                tooltip="Número total de parceiros cadastrados"
            />
            <StatCard
                title="Total de Cliques"
                value={stats.totalClicks}
                icon={MousePointer2}
                variant="success"
                tooltip="Soma total de cliques em todos os parceiros"
            />
            <StatCard
                title="Melhor Parceiro"
                value={stats.bestPartner}
                icon={Trophy}
                variant="warning"
                tooltip="Parceiro com o maior número de cliques"
            />
            <StatCard
                title="Usuários Únicos"
                value={stats.uniqueUsers}
                icon={UserCheck}
                variant="default"
                tooltip="Total de usuários únicos que clicaram em algum parceiro"
            />
            <StatCard
                title="Cliques por Parceiro"
                value={stats.clicksPerPartner.toFixed(2)}
                icon={TrendingUp}
                variant="success"
                tooltip="Média de cliques dividida pelo número de parceiros"
            />
            <StatCard
                title="Cliques por Usuário"
                value={stats.clicksPerUser.toFixed(2)}
                icon={UserPlus}
                variant="default"
                tooltip="Média de cliques dividida pelo número de usuários únicos"
            />
        </div>
    );
}
