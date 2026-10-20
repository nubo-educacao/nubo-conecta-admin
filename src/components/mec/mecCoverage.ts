import type { FunnelChartStep } from "@/components/analytics/FunnelChart";
import type { MecDashboardData } from "@/services/mecDashboardService";
import type { InstrumentationCoverage } from "@/types/productAnalytics";
import { formatBrt } from "@/components/b2b/funnelPeriod";

/**
 * Redirect coverage (D-i/D-m) decides whether a zero redirect is a measurement.
 * not_instrumented, or unknown with nothing observed, is absence of measurement — never 0.
 */
export function isRedirectUnmeasured(coverage: InstrumentationCoverage | undefined, observedRedirects: number): boolean {
  return coverage?.status === "not_instrumented" || (coverage?.status === "unknown" && observedRedirects === 0);
}

export function mecCohortSteps(data: MecDashboardData): FunnelChartStep[] {
  const coverage = data.coverage.redirect;
  const unmeasured = isRedirectUnmeasured(coverage, data.cohort.redirectors);
  return [
    { key: "viewers", label: "Viu o card", value: data.cohort.viewers },
    { key: "clickers", label: "Clicou após ver", value: data.cohort.clickers },
    {
      key: "redirectors",
      label: "Redirect ao portal oficial",
      value: unmeasured ? null : data.cohort.redirectors,
      coverage,
      notInstrumented: unmeasured,
    },
  ];
}

export function redirectCoverageText(coverage: InstrumentationCoverage | undefined): string {
  const since = coverage?.verified_since ? formatBrt(coverage.verified_since) : null;
  switch (coverage?.status) {
    case "instrumented":
      return since ? `Redirect instrumentado em todo o período (verificado desde ${since}).` : "Redirect instrumentado em todo o período.";
    case "partial":
      return `Cobertura parcial: redirect medido só a partir de ${since ?? "data não informada"}; antes disso não há medição. A taxa da etapa fica indisponível.`;
    case "not_instrumented":
      return `Redirect não instrumentado antes de ${since ?? "data não informada"}: este período não tem medição de redirect (não é zero).`;
    default:
      return coverage?.first_observed_at
        ? `Início da instrumentação do redirect não verificado. Primeiro redirect observado em ${formatBrt(coverage.first_observed_at)} (não é a data de instrumentação); a taxa da etapa fica indisponível.`
        : "Início da instrumentação do redirect não verificado e nenhum redirect observado no período — ausência de medição, não zero.";
  }
}
