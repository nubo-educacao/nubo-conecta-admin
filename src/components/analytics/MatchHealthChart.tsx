import { PieChart, Pie, Cell, ResponsiveContainer, Tooltip, Legend } from "recharts";
import { Skeleton } from "@/components/ui/skeleton";
import { Activity } from "lucide-react";
import { useCommandCenterDemographics } from "@/hooks/useAnalyticsData";

const COLORS = {
    with: "hsl(var(--success))",
    without: "hsl(var(--muted-foreground))",
};

/**
 * Saúde do motor de match: proporção de usuários com pelo menos uma
 * oportunidade compatível.
 *
 * É pizza e não funil de propósito (ADR-0027). Match não é etapa por onde a
 * pessoa passa a caminho de converter — é um estado do catálogo em relação ao
 * perfil. Tratá-lo como etapa de funil sugeria uma taxa de queda que não existe.
 */
export function MatchHealthChart() {
    const { data, isLoading, error } = useCommandCenterDemographics();

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
                    <p className="text-sm text-muted-foreground">Usuários com ao menos uma oportunidade compatível</p>
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
        { name: "Com match", value: with_match, fill: COLORS.with },
        { name: "Sem match", value: without_match, fill: COLORS.without },
    ];

    const pct = total > 0 ? Math.round((with_match / total) * 100) : 0;

    return (
        <div className="chart-container">
            <div className="mb-6 flex flex-col gap-1">
                <h3 className="text-lg font-semibold font-display">Saúde do Match</h3>
                <p className="text-sm text-muted-foreground">
                    {pct}% dos {total.toLocaleString("pt-BR")} usuários têm ao menos uma oportunidade compatível
                </p>
            </div>

            {total === 0 ? (
                <div className="flex h-[260px] items-center justify-center text-sm text-muted-foreground">
                    Nenhum usuário cadastrado no período.
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
