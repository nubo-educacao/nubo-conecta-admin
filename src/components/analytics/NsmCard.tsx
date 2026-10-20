// NSM do Command Center (NUB-RD-89d): encaminhamentos por aluno ativo, por semestre.
// Contrato congelado get_command_center_nsm (TP-D rev.3, D-d):
// - numerador = MEC redirect + parceiro redirected + parceiro submitted;
//   legado v0 (redirect externo) fica fora, em linha própria;
// - denominador = active_users deduplicado (nunca activity_days + live_fallback);
// - per_active_user NULL = indisponível com reason, nunca zero.
import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Target } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { fetchNsm, productAnalyticsKeys } from "@/services/productAnalyticsService";
import type { AttributionFilter } from "@/lib/attributionFilter";
import type { NsmWindow } from "@/types/productAnalytics";
import { ActivityCoverageNote, coverageText, fmtInt } from "./ActivityCoverageNote";

/** Semestre corrente em America/Sao_Paulo: S1 jan–jun, S2 jul–dez. */
export function currentSemester(now: Date): string {
  const [year, month] = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit" })
    .format(now)
    .split("-")
    .map(Number);
  return `${year}-S${month <= 6 ? 1 : 2}`;
}

/** Semestre imediatamente anterior (S2 → S1 do mesmo ano; S1 → S2 do ano anterior). */
export function adjacentSemester(semester: string): string {
  const year = Number(semester.slice(0, 4));
  return semester.endsWith("S2") ? `${year}-S1` : `${year - 1}-S2`;
}

const sameSemesterLastYear = (semester: string) => `${Number(semester.slice(0, 4)) - 1}${semester.slice(4)}`;

const REASONS: Record<string, string> = {
  zero_denominator: "sem alunos ativos no semestre",
  capture_failure: "houve falha de captura de conversões no semestre; taxa íntegra indisponível",
  incomplete_mec_coverage: "cobertura do redirect MEC incompleta no semestre",
};
const reasonText = (reason: string | null) => (reason ? REASONS[reason] ?? reason : "cobertura insuficiente para taxa íntegra");

const fmtPerUser = (v: number) => v.toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

type CompareMode = "yoy" | "adjacent";

interface NsmCardProps {
  attribution?: AttributionFilter;
}

export function NsmCard({ attribution = {} }: NsmCardProps) {
  const options = useMemo(() => {
    const list = [currentSemester(new Date())];
    while (list.length < 6) list.push(adjacentSemester(list[list.length - 1]));
    return list;
  }, []);
  const [semester, setSemester] = useState(options[0]);
  const [mode, setMode] = useState<CompareMode>("yoy");
  // yoy deixa o servidor aplicar o padrão (mesmo semestre do ano anterior).
  const compare = mode === "adjacent" ? adjacentSemester(semester) : undefined;

  const { data, isLoading, isError } = useQuery({
    queryKey: productAnalyticsKeys.nsm(semester, compare, attribution),
    queryFn: () => fetchNsm(semester, compare, attribution),
  });

  return (
    <section className="stat-card space-y-4" aria-labelledby="nsm-title">
      <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div className="flex items-center gap-3">
          <div className="rounded-lg bg-primary/10 p-2">
            <Target className="h-5 w-5 text-primary" aria-hidden />
          </div>
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">North Star Metric</p>
            <h3 id="nsm-title" className="font-semibold text-base sm:text-lg">
              Encaminhamentos por aluno ativo, {data?.semester ?? semester}
            </h3>
          </div>
        </div>
        <div className="flex flex-wrap gap-3 text-sm">
          <label className="flex flex-col gap-1">
            <span className="text-xs text-muted-foreground">Semestre</span>
            <select className="h-9 rounded-md border border-input bg-background px-2" value={semester} onChange={(e) => setSemester(e.target.value)}>
              {options.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          </label>
          <label className="flex flex-col gap-1">
            <span className="text-xs text-muted-foreground">Comparar com</span>
            <select className="h-9 rounded-md border border-input bg-background px-2" value={mode} onChange={(e) => setMode(e.target.value as CompareMode)}>
              <option value="yoy">Mesmo semestre do ano anterior ({sameSemesterLastYear(semester)})</option>
              <option value="adjacent">Semestre anterior, S1↔S2 ({adjacentSemester(semester)})</option>
            </select>
          </label>
        </div>
      </div>

      {isLoading ? (
        <div role="status" aria-label="Carregando NSM"><Skeleton className="h-32 w-full" /></div>
      ) : isError || !data ? (
        <p role="alert" className="text-sm text-destructive">Não foi possível carregar a NSM. Use Atualizar para tentar novamente.</p>
      ) : (
        <>
          <div className="grid gap-4 lg:grid-cols-[1fr_1fr_1fr]">
            <NsmValue window={data} />
            <div className="space-y-2">
              <p data-testid="nsm-referrals" className="text-sm">
                <span className="text-lg font-semibold">{fmtInt(data.referrals.total)}</span> encaminhamentos no semestre
              </p>
              <ul aria-label="Composição do numerador" className="space-y-1 text-sm">
                <li>MEC redirect: <strong>{fmtInt(data.referrals.composition.mec_redirect)}</strong></li>
                <li>Parceiro redirecionada: <strong>{fmtInt(data.referrals.composition.partner_redirected)}</strong></li>
                <li>Parceiro submetida: <strong>{fmtInt(data.referrals.composition.partner_submitted)}</strong></li>
              </ul>
              <p data-testid="nsm-legacy" className="text-xs text-muted-foreground border-t border-border pt-2">
                Legado v0 (redirect externo): {fmtInt(data.referrals.composition.legacy_external_redirect)} — fora do numerador da NSM.
              </p>
            </div>
            <div className="space-y-1 text-sm">
              <p data-testid="nsm-active">
                <span className="text-lg font-semibold">{fmtInt(data.active_users_source.deduplicated_total)}</span> alunos ativos (deduplicados)
              </p>
              <p className="text-xs text-muted-foreground">
                {fmtInt(data.active_users_source.activity_days)} pela captura diária e {fmtInt(data.active_users_source.live_fallback)} por
                fontes vivas, com sobreposição — os subtotais não se somam.
              </p>
            </div>
          </div>

          <div role="group" aria-label="Comparação" className="rounded-lg border border-border p-3 text-sm space-y-1">
            <p className="font-medium">Comparação: <span>{data.comparison.semester}</span></p>
            <NsmCompare window={data.comparison} />
            <p className="text-xs text-muted-foreground">{data.seasonality_note}</p>
          </div>

          <section aria-label="Cobertura da NSM" className="space-y-1 text-xs text-muted-foreground">
            <ActivityCoverageNote coverage={data.coverage.activity} />
            <p>{coverageText("Redirect MEC", data.coverage.mec_redirect)}</p>
            <p>
              Parceiro: {fmtInt(data.coverage.application_time_basis.captured_terminal)} candidaturas com instante terminal capturado;{" "}
              {fmtInt(data.coverage.application_time_basis.created_at_proxy)} candidaturas históricas datadas pelo início (created_at) —
              aproximação, não data de submissão
              {data.coverage.application_time_basis.post_capture_missing_snapshot > 0 &&
                `; ${fmtInt(data.coverage.application_time_basis.post_capture_missing_snapshot)} sem snapshot após a ativação da captura`}
              .
            </p>
          </section>
        </>
      )}
    </section>
  );
}

function NsmValue({ window }: { window: NsmWindow }) {
  return (
    <div>
      <p data-testid="nsm-value" className="text-3xl font-bold font-display">
        {window.per_active_user === null ? "Indisponível" : fmtPerUser(window.per_active_user)}
      </p>
      {window.per_active_user === null ? (
        <p className="text-xs text-muted-foreground">Taxa indisponível: {reasonText(window.coverage.reason)}.</p>
      ) : (
        <p className="text-xs text-muted-foreground">encaminhamentos por aluno ativo</p>
      )}
    </div>
  );
}

function NsmCompare({ window }: { window: NsmWindow }) {
  return (
    <p>
      {window.per_active_user === null ? (
        <>
          <span>Indisponível</span> <span className="text-xs text-muted-foreground">({reasonText(window.coverage.reason)})</span>
        </>
      ) : (
        <span>{fmtPerUser(window.per_active_user)} por aluno ativo</span>
      )}
      {" · "}
      {fmtInt(window.referrals.total)} encaminhamentos · {fmtInt(window.active_users_source.deduplicated_total)} ativos
    </p>
  );
}
