import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Tooltip, Cell } from "recharts";
import { Skeleton } from "@/components/ui/skeleton";
import { Users } from "lucide-react";
import { useCommandCenterDemographics } from "@/hooks/useAnalyticsData";
import type { DistributionSlice } from "@/lib/analytics-queries";

const UNANSWERED = "Não respondeu";

const BAR_COLORS = [
    "hsl(var(--primary))",
    "hsl(var(--chart-2))",
    "hsl(var(--chart-3))",
    "hsl(var(--chart-4))",
    "hsl(var(--chart-5))",
];

/** O bucket "Não respondeu" é cinza de propósito: é ausência de dado, não categoria. */
const barColor = (label: string, index: number) =>
    label === UNANSWERED ? "hsl(var(--muted-foreground))" : BAR_COLORS[index % BAR_COLORS.length];

function DistributionChart({
    title,
    subtitle,
    data,
}: {
    title: string;
    subtitle: string;
    data: DistributionSlice[];
}) {
    const total = data.reduce((acc, d) => acc + d.value, 0);
    const answered = data
        .filter((d) => d.label !== UNANSWERED)
        .reduce((acc, d) => acc + d.value, 0);
    const coverage = total > 0 ? Math.round((answered / total) * 100) : 0;

    return (
        <div className="chart-container">
            <div className="mb-6 flex flex-col gap-1">
                <h3 className="text-lg font-semibold font-display">{title}</h3>
                <p className="text-sm text-muted-foreground">
                    {subtitle} · {coverage}% preencheram
                </p>
            </div>

            {total === 0 ? (
                <div className="flex h-[220px] items-center justify-center text-sm text-muted-foreground">
                    Sem dados.
                </div>
            ) : (
                <ResponsiveContainer width="100%" height={220}>
                    <BarChart data={data} layout="vertical" margin={{ left: 8, right: 16 }}>
                        <XAxis type="number" hide />
                        <YAxis
                            type="category"
                            dataKey="label"
                            width={140}
                            tick={{ fontSize: 12 }}
                            axisLine={false}
                            tickLine={false}
                        />
                        <Tooltip
                            formatter={(value: number) => [`${value.toLocaleString("pt-BR")} usuários`, ""]}
                        />
                        <Bar dataKey="value" radius={[0, 4, 4, 0]}>
                            {data.map((entry, i) => (
                                <Cell key={entry.label} fill={barColor(entry.label, i)} />
                            ))}
                        </Bar>
                    </BarChart>
                </ResponsiveContainer>
            )}
        </div>
    );
}

/**
 * Quatro dimensões demográficas num único fetch (TP-1 1B t6).
 *
 * O plano original previa duas — escolaridade e renda. `race` e `school_type`
 * chegaram por fora, na QA-8, e entram aqui de graça.
 *
 * Todas exibem "Não respondeu" como faixa explícita. Sem isso o gráfico mente:
 * uma distribuição calculada só sobre quem respondeu parece completa, e a
 * cobertura real (que aqui aparece no subtítulo) some.
 */
export function DemographicsCharts() {
    const { data, isLoading, error } = useCommandCenterDemographics();

    if (isLoading) {
        return (
            <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
                {[...Array(4)].map((_, i) => (
                    <Skeleton key={i} className="h-[290px] w-full" />
                ))}
            </section>
        );
    }

    if (error || !data) {
        return (
            <div className="chart-container">
                <div className="mb-6 flex flex-col gap-1">
                    <h3 className="text-lg font-semibold font-display">Demografia</h3>
                </div>
                <div className="flex h-[220px] flex-col items-center justify-center text-muted-foreground">
                    <Users className="mb-4 h-12 w-12 opacity-50" />
                    <p className="text-sm">Não foi possível carregar os dados demográficos</p>
                </div>
            </div>
        );
    }

    return (
        <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
            <DistributionChart
                title="Escolaridade"
                subtitle="Nível declarado no perfil"
                data={data.education}
            />
            <DistributionChart
                title="Renda per capita"
                subtitle="Faixa de renda familiar por pessoa"
                data={data.income}
            />
            <DistributionChart
                title="Raça/cor"
                subtitle="Autodeclaração"
                data={data.race}
            />
            <DistributionChart
                title="Tipo de escola"
                subtitle="Origem no ensino médio"
                data={data.school_type}
            />
        </section>
    );
}
