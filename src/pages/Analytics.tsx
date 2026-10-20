// Analytics de Produto (NUB-RD-89). Consome só o contrato congelado do TP-D
// (productAnalyticsService) e o NsmCard. O funil global (TP-E) fica no Command Center.
//
// A NSM usa o semestre escolhido no próprio card. Período de atividade: L1, L2
// (coorte de ativos/encaminhamentos) e interesse por cliques. Saúde do Match,
// demografia, cursos, preferências e localizações são snapshots atuais / todo o
// histórico: recebem só first-touch.
import { useCallback, useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { PieChart } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { DateRangeFilter, type DateRangeValue } from "@/components/analytics/DateRangeFilter";
import { NsmCard } from "@/components/analytics/NsmCard";
import { OpportunityInterestChart } from "@/components/analytics/OpportunityInterestChart";
import { MatchHealthChart } from "@/components/analytics/MatchHealthChart";
import { DemographicsCharts } from "@/components/analytics/DemographicsCharts";
import { TopCoursesChart } from "@/components/analytics/TopCoursesChart";
import { UserPreferencesChart } from "@/components/analytics/UserPreferencesChart";
import { LocationChart } from "@/components/analytics/LocationChart";
import { LocationPreferenceChart } from "@/components/analytics/LocationPreferenceChart";
import { ActivityCoverageNote, fmtDate, fmtDateTime, fmtInt, fmtRate } from "@/components/analytics/ActivityCoverageNote";
import { AttributionUrlFilter, useAttributionUrlState } from "@/components/filters/AttributionUrlFilter";
import { commandCenterDateRange } from "@/lib/commandCenterDateRange";
import { hasAttributionFilter, type AttributionFilter } from "@/lib/attributionFilter";
import { fetchL1, fetchL2, productAnalyticsKeys } from "@/services/productAnalyticsService";
import type { AnalyticsRange, L1Metrics, L2Metrics } from "@/types/productAnalytics";

const UNAVAILABLE = "Indisponível";

const fmtDays = (d: number) => `${d.toLocaleString("pt-BR", { maximumFractionDigits: 1 })} ${d === 1 ? "dia" : "dias"}`;

/** Período normalizado pelo servidor: [from, to) em dias inteiros BRT. */
function activityPeriodText(period: { from: string | null; to: string | null }) {
  const from = fmtDate(period.from);
  const lastDay = period.to ? fmtDate(new Date(new Date(period.to).getTime() - 1).toISOString()) : null;
  if (!from && !lastDay) return "todo o histórico";
  if (!from) return `todo o histórico até ${lastDay}`;
  return lastDay ? `${from} a ${lastDay}` : `desde ${from}`;
}

const Analytics = () => {
  const queryClient = useQueryClient();
  const [selectedRange, setSelectedRange] = useState<DateRangeValue>("30d");
  const [customDate, setCustomDate] = useState<Date>();
  const [lastUpdate, setLastUpdate] = useState<Date>(new Date());
  const [isRefreshing, setIsRefreshing] = useState(false);
  const dateRange = useMemo(() => commandCenterDateRange(selectedRange, lastUpdate, customDate), [selectedRange, lastUpdate, customDate]);

  const [attribution, setAttribution] = useAttributionUrlState();

  const handleRangeChange = useCallback((range: DateRangeValue) => {
    setSelectedRange(range);
    setLastUpdate(new Date());
  }, []);

  const handleRefresh = useCallback(async () => {
    setIsRefreshing(true);
    try {
      await queryClient.invalidateQueries();
      setLastUpdate(new Date());
    } finally {
      setIsRefreshing(false);
    }
  }, [queryClient]);

  return (
    <div className="min-h-screen bg-background">
      <header className="border-b border-border pb-4">
        <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-primary/10 text-primary shrink-0">
              <PieChart className="h-5 w-5" aria-hidden />
            </div>
            <div>
              <h1 className="text-xl font-bold font-display tracking-tight">Analytics de Produto</h1>
              <p className="text-xs text-muted-foreground">North Star, valor da feature (L1) e qualidade do motor (L2).</p>
            </div>
          </div>
          <DateRangeFilter
            selectedRange={selectedRange}
            onDateChange={handleRangeChange}
            onCustomDateChange={setCustomDate}
            onRefresh={handleRefresh}
            isRefreshing={isRefreshing}
          />
        </div>
        <div className="mt-3">
          <AttributionUrlFilter value={attribution} onChange={setAttribution} />
        </div>
        <p className="mt-3 text-sm text-muted-foreground">
          A NSM usa o semestre escolhido no próprio card. O período de atividade filtra a L1, a coorte de ativos e os
          encaminhamentos da L2 e o interesse por cliques. Os retratos atuais no fim da página não mudam com o período.
        </p>
        {hasAttributionFilter(attribution) && (
          <p className="text-sm text-muted-foreground">
            Recorte por campanha/divulgador (first-touch) aplicado a todas as seções, com a mesma regra do Command Center.
          </p>
        )}
      </header>

      <main className="py-4 sm:py-6 space-y-4 sm:space-y-6">
        {/* North Star Metric (NUB-RD-89): semestre próprio, recorte first-touch */}
        <NsmCard attribution={attribution} />
        <L1Section range={dateRange} attribution={attribution} />
        <L2Section range={dateRange} attribution={attribution} />

        <section aria-labelledby="interest-title" className="space-y-2">
          <h2 id="interest-title" className="text-lg font-semibold">Interesse por cliques</h2>
          <OpportunityInterestChart dateRange={dateRange} attribution={attribution} />
        </section>

        <section aria-labelledby="snapshots-title" className="space-y-4">
          <div>
            <h2 id="snapshots-title" className="text-lg font-semibold">
              Retrato atual / histórico disponível — não limitado pelo período de atividade
            </h2>
            <p className="text-sm text-muted-foreground">
              Saúde do Match, demografia, cursos, preferências e localizações respeitam o recorte first-touch; mudar o período
              não os altera.
            </p>
          </div>
          <div className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
            <MatchHealthChart attribution={attribution} />
            <TopCoursesChart attribution={attribution} />
          </div>
          <DemographicsCharts attribution={attribution} />
          <div className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
            <UserPreferencesChart attribution={attribution} />
            <LocationChart attribution={attribution} />
          </div>
          <LocationPreferenceChart attribution={attribution} />
        </section>
      </main>
    </div>
  );
};

interface SectionProps {
  range: AnalyticsRange;
  attribution: AttributionFilter;
}

function SectionState({ isLoading, label }: { isLoading: boolean; label: string }) {
  return isLoading ? (
    <div role="status" aria-label={`Carregando ${label}`}><Skeleton className="h-32 w-full" /></div>
  ) : (
    <p role="alert" className="text-sm text-destructive">Não foi possível carregar a {label}. Use Atualizar para tentar novamente.</p>
  );
}

function L1Section({ range, attribution }: SectionProps) {
  const { data, isLoading, isError } = useQuery({
    queryKey: productAnalyticsKeys.l1(range, attribution),
    queryFn: () => fetchL1(range, attribution),
  });
  return (
    <section aria-labelledby="l1-title" className="chart-container space-y-4">
      <h2 id="l1-title" className="text-lg font-semibold">L1 — valor da feature</h2>
      {isLoading || isError || !data ? <SectionState isLoading={isLoading} label="L1" /> : <L1Content data={data} />}
    </section>
  );
}

function L1Content({ data }: { data: L1Metrics }) {
  const adoption = data.cloudinha_adoption;
  const adoptionRate = fmtRate(adoption.rate);
  const time = data.time_to_first_application;
  return (
    <>
      <div className="grid gap-4 md:grid-cols-2">
        <div data-testid="l1-adoption" className="rounded-lg border border-border p-3 space-y-1">
          <h3 className="text-sm font-medium">Adoção da Cloudinha</h3>
          <p className="text-2xl font-bold">{adoptionRate ?? UNAVAILABLE}</p>
          {adoptionRate ? (
            <p className="text-sm">{fmtInt(adoption.talked)} de {fmtInt(adoption.active)} ativos conversaram · n = {fmtInt(adoption.n)}</p>
          ) : (
            <p className="text-sm text-muted-foreground">Sem alunos ativos no período para formar a base.</p>
          )}
          <p className="text-xs text-muted-foreground">Conta só mensagens do aluno (não system_intent).</p>
        </div>
        <div data-testid="l1-time" className="rounded-lg border border-border p-3 space-y-1">
          <h3 className="text-sm font-medium">Tempo até a 1ª candidatura</h3>
          {time.n === 0 || time.median_days === null ? (
            <p className="text-sm">Sem candidaturas iniciadas no período.</p>
          ) : (
            <p className="text-sm">
              <span className="text-2xl font-bold">mediana {fmtDays(time.median_days)}</span>{" "}
              · p75 {time.p75_days === null ? UNAVAILABLE.toLowerCase() : fmtDays(time.p75_days)} · n = {fmtInt(time.n)}
            </p>
          )}
          <p className="text-xs text-muted-foreground">
            Do cadastro do perfil titular ao início da primeira candidatura (não é tempo até submissão).
            {data.coverage.excluded_negative_durations > 0 &&
              ` ${fmtInt(data.coverage.excluded_negative_durations)} candidaturas com duração negativa excluídas.`}
          </p>
        </div>
      </div>

      <div className="overflow-x-auto">
        <table aria-label="Retenção por semestre" className="w-full text-sm">
          <thead>
            <tr className="text-left text-muted-foreground">
              <th className="py-1 pr-3 font-medium">Semestre</th>
              <th className="py-1 pr-3 font-medium">Ativos</th>
              <th className="py-1 pr-3 font-medium">Ativos no semestre seguinte</th>
              <th className="py-1 font-medium">Retenção</th>
            </tr>
          </thead>
          <tbody>
            {data.retention_by_semester.map((r) => (
              <tr key={r.semester} className="border-t border-border">
                <td className="py-1 pr-3">{r.semester}</td>
                <td className="py-1 pr-3">{fmtInt(r.active)}</td>
                <td className="py-1 pr-3">{fmtInt(r.retained_next)}</td>
                <td className="py-1">
                  {fmtRate(r.rate) ?? (r.complete ? `${UNAVAILABLE} (sem base)` : "provisório — semestre seguinte em andamento")}
                  {r.rate !== null && !r.complete && " (provisório)"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="space-y-1 text-xs text-muted-foreground">
        <p>Período de atividade em dias inteiros (horário de Brasília): {activityPeriodText(data.coverage.activity_period)}.</p>
        <ActivityCoverageNote coverage={data.coverage.activity} />
      </div>
    </>
  );
}

function L2Section({ range, attribution }: SectionProps) {
  const { data, isLoading, isError } = useQuery({
    queryKey: productAnalyticsKeys.l2(range, attribution),
    queryFn: () => fetchL2(range, attribution),
  });
  return (
    <section aria-labelledby="l2-title" className="chart-container space-y-4">
      <h2 id="l2-title" className="text-lg font-semibold">L2 — qualidade do motor</h2>
      {isLoading || isError || !data ? <SectionState isLoading={isLoading} label="L2" /> : <L2Content data={data} />}
    </section>
  );
}

const DOMAINS = [["mec", "MEC"], ["partner", "Parceiro"]] as const;

function L2Content({ data }: { data: L2Metrics }) {
  const temporal = data.match_contribution.temporal;
  const untimed = data.match_contribution.untimed_association;
  const temporalRate = fmtRate(temporal.rate);
  return (
    <>
      <p className="text-sm text-muted-foreground">
        Snapshot atual de {fmtDateTime(data.scope.snapshot_at)} — catálogo e resultados de match não são reconstruídos
        historicamente; o período seleciona a coorte de ativos e os encaminhamentos. Identidade: {data.scope.identity}.
      </p>
      <div className="grid gap-4 md:grid-cols-2">
        <div className="overflow-x-auto">
          <table aria-label="Alcance do motor" className="w-full text-sm">
            <caption className="text-left text-sm font-medium pb-1">Alcance do motor — {data.scope.engine_reach}</caption>
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1 pr-3 font-medium">Domínio</th>
                <th className="py-1 pr-3 font-medium">Ativos com match</th>
                <th className="py-1 font-medium">Taxa</th>
              </tr>
            </thead>
            <tbody>
              {DOMAINS.map(([key, label]) => {
                const r = data.engine_reach[key];
                return (
                  <tr key={key} className="border-t border-border">
                    <td className="py-1 pr-3">{label}</td>
                    <td className="py-1 pr-3">{fmtInt(r.active_with_match)} de {fmtInt(r.active)}</td>
                    <td className="py-1">{fmtRate(r.rate) ?? UNAVAILABLE}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <div className="overflow-x-auto">
          <table aria-label="Cobertura de catálogo" className="w-full text-sm">
            <caption className="text-left text-sm font-medium pb-1">Cobertura de catálogo — {data.scope.catalog_coverage}</caption>
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1 pr-3 font-medium">Domínio</th>
                <th className="py-1 pr-3 font-medium">Recomendadas no catálogo</th>
                <th className="py-1 font-medium">Taxa</th>
              </tr>
            </thead>
            <tbody>
              {DOMAINS.map(([key, label]) => {
                const r = data.catalog_coverage[key];
                return (
                  <tr key={key} className="border-t border-border">
                    <td className="py-1 pr-3">{label}</td>
                    <td className="py-1 pr-3">{fmtInt(r.recommended)} de {fmtInt(r.catalog)}</td>
                    <td className="py-1">{fmtRate(r.rate) ?? UNAVAILABLE}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {/* Temporal e associação sem ordem são conjuntos disjuntos: nunca somados. */}
      <div className="grid gap-4 md:grid-cols-2">
        <div data-testid="l2-temporal" className="rounded-lg border border-border p-3 space-y-1">
          <h3 className="text-sm font-medium">Contribuição do match para o encaminhamento</h3>
          {temporal.since === null ? (
            <p className="text-sm">Captura ainda não ativada — sem contribuição temporal medida.</p>
          ) : (
            <>
              <p className="text-sm">
                desde {fmtDate(temporal.since)}: {fmtInt(temporal.conversions_with_prior_match)} de {fmtInt(temporal.conversions_total)}{" "}
                encaminhamentos partiram de um match anterior
              </p>
              <p className="text-2xl font-bold">
                {temporalRate === null ? UNAVAILABLE : temporal.coverage.status === "instrumented" ? temporalRate : `${temporalRate} (taxa observada)`}
              </p>
              {temporal.coverage.capture_failures > 0 && (
                <p className="text-xs text-muted-foreground">
                  {fmtInt(temporal.coverage.capture_failures)} {temporal.coverage.capture_failures === 1 ? "falha" : "falhas"} de captura
                  no período — a taxa não é completa.
                </p>
              )}
              <p className="text-xs text-muted-foreground">{temporal.coverage.note}</p>
            </>
          )}
        </div>
        <div data-testid="l2-untimed" className="rounded-lg border border-dashed border-border p-3 space-y-1">
          <h3 className="text-sm font-medium">{untimed.label}</h3>
          <p className="text-2xl font-bold">{fmtInt(untimed.count)}</p>
          <p className="text-xs text-muted-foreground">
            {untimed.scope}. Escopo próprio, não somada à contribuição temporal.
          </p>
        </div>
      </div>

      <div className="space-y-1 text-xs text-muted-foreground">
        <p>Período de atividade em dias inteiros (horário de Brasília): {activityPeriodText(data.coverage.activity_period)}.</p>
        {data.coverage.excluded_unresolved_profile > 0 && (
          <p>
            {fmtInt(data.coverage.excluded_unresolved_profile)} linhas de match de perfis sem elo comprovado (dependentes) ficaram
            fora do alcance.
          </p>
        )}
        {data.coverage.post_capture_missing_snapshot > 0 && (
          <p>{fmtInt(data.coverage.post_capture_missing_snapshot)} conversões após a ativação sem snapshot de match.</p>
        )}
      </div>
    </>
  );
}

export default Analytics;
