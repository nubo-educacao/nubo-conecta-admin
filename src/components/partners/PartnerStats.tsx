// PartnerStats.tsx — Sprint 3.8
// Simplified stats: total partners + total opportunities.

import { Users, Layers } from "lucide-react";
import { StatCard } from "@/components/analytics/StatCard";
import { PartnerStats as PartnerStatsType } from "@/services/partnersService";

interface PartnerStatsProps {
    stats: PartnerStatsType;
}

export function PartnerStats({ stats }: PartnerStatsProps) {
    return (
        <div className="grid gap-4 md:grid-cols-2">
            <StatCard
                title="Total de Parceiros"
                value={stats.totalPartners}
                icon={Users}
                variant="default"
                tooltip="Número de instituições parceiras cadastradas"
            />
            <StatCard
                title="Total de Oportunidades"
                value={stats.totalOpportunities}
                icon={Layers}
                variant="success"
                tooltip="Número total de oportunidades parceiras cadastradas"
            />
        </div>
    );
}
