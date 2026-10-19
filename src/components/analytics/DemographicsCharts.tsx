import { useId } from "react";
import type { AttributionFilter } from "@/lib/attributionFilter";
import { attributionArg } from "@/lib/commandCenterAttribution";
import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Tooltip, Cell } from "recharts";
import { Skeleton } from "@/components/ui/skeleton";
import { Users } from "lucide-react";
import { useCommandCenterDemographics } from "@/hooks/useAnalyticsData";
import type { DemographicsCoverage, DistributionSlice } from "@/lib/analytics-queries";
import { QUOTA_COLOR, UNANSWERED, sliceFill } from "./demographicsFill";

const QUOTA_NOTE = "Cota indica elegibilidade declarada, não autodeclaração.";

const pct = (value: number) => `${value.toLocaleString("pt-BR", { maximumFractionDigits: 1 })}%`;

function CoverageLine({ id, coverage }: { id: string; coverage: DemographicsCoverage[keyof DemographicsCoverage] }) {
    const declined = "declined" in coverage ? coverage.declined : 0;
    return (
        <p data-testid={`coverage-${id}`} className="text-sm text-muted-foreground">
            {coverage.covered_pct === null
                ? "Sem base para calcular a cobertura"
                : `Cobertura ${pct(coverage.covered_pct)} · Autodeclarado ${pct(coverage.self_declared_pct ?? 0)} · Inferido por cota ${pct(coverage.quota_inferred_pct ?? 0)}`}
            {declined > 0 && ` · ${declined.toLocaleString("pt-BR")} ${declined === 1 ? "preferiu" : "preferiram"} não informar`}
        </p>
    );
}

function ProvenanceLegend() {
    return (
        <div data-testid="provenance-legend" className="flex flex-col gap-1 text-xs text-muted-foreground">
            <div className="flex flex-wrap items-center gap-4">
                <span className="flex items-center gap-1.5">
                    <span aria-hidden className="h-3 w-3 rounded-sm" style={{ background: "hsl(var(--primary))" }} />
                    <span>Autodeclarado</span>
                </span>
                <span className="flex items-center gap-1.5">
                    <span
                        aria-hidden
                        className="h-3 w-3 rounded-sm"
                        style={{
                            background: `repeating-linear-gradient(45deg, ${QUOTA_COLOR} 0 2px, transparent 2px 4px)`,
                            border: `1px solid ${QUOTA_COLOR}`,
                        }}
                    />
                    <span>Inferido por cota</span>
                </span>
            </div>
            <p>{QUOTA_NOTE}</p>
        </div>
    );
}

function DistributionChart({
    id,
    title,
    subtitle,
    data,
    coverage,
}: {
    id: string;
    title: string;
    subtitle: string;
    data: DistributionSlice[];
    coverage?: DemographicsCoverage[keyof DemographicsCoverage];
}) {
    const patternId = `quota-${useId().replace(/:/g, "")}`;
    const total = data.reduce((acc, d) => acc + d.value, 0);
    const answered = data
        .filter((d) => d.label !== UNANSWERED)
        .reduce((acc, d) => acc + d.value, 0);
    const filled = total > 0 ? Math.round((answered / total) * 100) : 0;

    return (
        <div className="chart-container">
            <div className="mb-6 flex flex-col gap-1">
                <h3 className="text-lg font-semibold font-display">{title}</h3>
                {coverage ? (
                    <>
                        <p className="text-sm text-muted-foreground">{subtitle}</p>
                        <CoverageLine id={id} coverage={coverage} />
                        <ProvenanceLegend />
                    </>
                ) : (
                    <p className="text-sm text-muted-foreground">
                        {subtitle} · {filled}% preencheram
                    </p>
                )}
            </div>

            {total === 0 ? (
                <div className="flex h-[220px] items-center justify-center text-sm text-muted-foreground">
                    Sem dados.
                </div>
            ) : (
                <ResponsiveContainer width="100%" height={220}>
                    <BarChart data={data} layout="vertical" margin={{ left: 8, right: 16 }}>
                        <defs>
                            <pattern
                                id={patternId}
                                patternUnits="userSpaceOnUse"
                                width={6}
                                height={6}
                                patternTransform="rotate(45)"
                            >
                                <rect width={6} height={6} fill={QUOTA_COLOR} fillOpacity={0.25} />
                                <rect width={3} height={6} fill={QUOTA_COLOR} />
                            </pattern>
                        </defs>
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
                                <Cell key={entry.label} fill={sliceFill(entry, i, patternId)} />
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
 *
 * Raça e escola (NUB-RD-92) mostram, além da autodeclaração, a inferência por
 * cota em barras próprias, com a cobertura de cada fonte. É snapshot do estado
 * atual: só o recorte first-touch se aplica, não há período.
 */
export function DemographicsCharts({ attribution }: { attribution?: AttributionFilter } = {}) {
    const { data, isLoading, error } = useCommandCenterDemographics(...attributionArg(attribution));

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
                id="education"
                title="Escolaridade"
                subtitle="Nível declarado no perfil"
                data={data.education}
            />
            <DistributionChart
                id="income"
                title="Renda per capita"
                subtitle="Faixa de renda familiar por pessoa"
                data={data.income}
            />
            <DistributionChart
                id="race"
                title="Raça/cor"
                subtitle={data.coverage ? "Autodeclaração e inferência por cota" : "Autodeclaração"}
                data={data.race}
                coverage={data.coverage?.race}
            />
            <DistributionChart
                id="school_type"
                title="Tipo de escola"
                subtitle="Origem no ensino médio"
                data={data.school_type}
                coverage={data.coverage?.school_type}
            />
        </section>
    );
}
