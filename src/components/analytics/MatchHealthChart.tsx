import type { AttributionFilter } from "@/lib/attributionFilter";
import { attributionArg } from "@/lib/commandCenterAttribution";
import { PieChart, Pie, Cell, ResponsiveContainer, Tooltip, Legend } from "recharts";
import { Skeleton } from "@/components/ui/skeleton";
import { Activity } from "lucide-react";
import { useCommandCenterDemographics } from "@/hooks/useAnalyticsData";

const COLORS = {
    with: "hsl(var(--success))",
    without: "hsl(var(--muted-foreground))",
};

/**
 * Saúde do Match: proporção de usuários que concluíram o Match alguma vez, no
 * v0 (chat) ou no v1 (resultado gravado, MEC ou parceiro). with_match não diz
 * que o catálogo atual tem oportunidade compatível; resultado atual vem em
 * with_current_result (Complemento TP-1, D1).
 *
 * É pizza e não funil de propósito (ADR-0027): tratar o Match como etapa de
 * funil sugeria uma taxa de queda que não existe.
 */
export function MatchHealthChart({ attribution }: { attribution?: AttributionFilter } = {}) {
    const { data, isLoading, error } = useCommandCenterDemographics(...attributionArg(attribution));

    if (isLoading) {
        return (
            <div className="chart-container">
                <div className="mb-6 flex flex-col gap-1">
                    <Skeleton className="h-6 w-48" />
                    <Skeleton className="h-4 w-64" />
                </div>
                <Skeleton className="h-[260px] w-full" />
            </div>
        );
    }

    if (error || !data?.match_health) {
        return (
            <div className="chart-container">
                <div className="mb-6 flex flex-col gap-1">
                    <h3 className="text-lg font-semibold font-display">Saúde do Match</h3>
                    <p className="text-sm text-muted-foreground">Usuários que concluíram o Match alguma vez (v0 ou v1)</p>
                </div>
                <div className="flex h-[260px] flex-col items-center justify-center text-muted-foreground">
                    <Activity className="mb-4 h-12 w-12 opacity-50" />
                    <p className="text-sm">Não foi possível carregar a saúde do match</p>
                </div>
            </div>
        );
    }

    const { with_match, without_match, total } = data.match_health;

    const chartData = [
        { name: "Concluiu o Match", value: with_match, fill: COLORS.with },
        { name: "Não concluiu", value: without_match, fill: COLORS.without },
    ];

    const pct = total > 0 ? Math.round((with_match / total) * 100) : 0;

    return (
        <div className="chart-container">
            <div className="mb-6 flex flex-col gap-1">
                <h3 className="text-lg font-semibold font-display">Saúde do Match</h3>
                <p className="text-sm text-muted-foreground">
                    {pct}% dos {total.toLocaleString("pt-BR")} usuários concluíram o Match alguma vez (v0 ou v1)
                </p>
            </div>

            {total === 0 ? (
                <div className="flex h-[260px] items-center justify-center text-sm text-muted-foreground">
                    Nenhum perfil disponível no estado atual.
                </div>
            ) : (
                <ResponsiveContainer width="100%" height={260}>
                    <PieChart>
                        <Pie
                            data={chartData}
                            dataKey="value"
                            nameKey="name"
                            innerRadius={60}
                            outerRadius={95}
                            paddingAngle={2}
                        >
                            {chartData.map((entry) => (
                                <Cell key={entry.name} fill={entry.fill} />
                            ))}
                        </Pie>
                        <Tooltip
                            formatter={(value: number, name: string) => [
                                `${value.toLocaleString("pt-BR")} usuários`,
                                name,
                            ]}
                        />
                        <Legend />
                    </PieChart>
                </ResponsiveContainer>
            )}
        </div>
    );
}
