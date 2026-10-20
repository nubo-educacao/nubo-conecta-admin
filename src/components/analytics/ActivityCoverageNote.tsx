// Formatação e notas de cobertura compartilhadas pela NSM (Command Center) e
// pelas seções L1/L2 (Analytics). Contrato TP-D rev.3: taxas são frações e
// null é indisponível — nunca vira "0%".
import type { ActivityCoverage, InstrumentationCoverage } from "@/types/productAnalytics";

const TZ = "America/Sao_Paulo";

export const fmtInt = (n: number) => n.toLocaleString("pt-BR");

export const fmtDate = (iso?: string | null) =>
  iso ? new Date(iso).toLocaleDateString("pt-BR", { timeZone: TZ }) : null;

export const fmtDateTime = (iso?: string | null) =>
  iso
    ? new Date(iso).toLocaleString("pt-BR", { timeZone: TZ, dateStyle: "short", timeStyle: "short" })
    : null;

/** Fração → "12,3%". null → null (quem chama decide o rótulo de indisponível). */
export function fmtRate(rate: number | null | undefined): string | null {
  if (rate === null || rate === undefined) return null;
  return `${(rate * 100).toLocaleString("pt-BR", { maximumFractionDigits: 1 })}%`;
}

const SOURCE_LABEL: Record<"session" | "engagement" | "chat", string> = {
  session: "Sessão",
  engagement: "Evento de engajamento",
  chat: "Mensagem do aluno à Cloudinha",
};

/** Cobertura D-m de uma fonte de evento. first_observed_at nunca vira data de implantação. */
export function coverageText(label: string, c?: InstrumentationCoverage | null): string | null {
  if (!c) return null;
  const verified = fmtDate(c.verified_since);
  const first = fmtDate(c.first_observed_at);
  switch (c.status) {
    case "instrumented":
      return verified ? `${label}: instrumentado desde ${verified}.` : `${label}: instrumentado no período.`;
    case "partial":
      return `${label}: janela parcial${verified ? ` (verificado desde ${verified})` : ""} — contagem observada, sem taxa completa.`;
    case "not_instrumented":
      return verified ? `${label}: não instrumentado antes de ${verified}.` : `${label}: não instrumentado no período.`;
    case "observed":
      return `${label}: valores observados${c.reason ? ` — ${c.reason}` : ""}.`;
    default:
      return first
        ? `${label}: cobertura desconhecida — primeiro evento observado em ${first}.`
        : `${label}: cobertura desconhecida — ainda sem eventos observados.`;
  }
}

/** "Aluno ativo" = atividade autenticada (sessão, engajamento logado ou mensagem real). */
export function ActivityCoverageNote({ coverage }: { coverage: ActivityCoverage }) {
  const sources = coverage.first_observed_by_source ?? {};
  const captureStart = fmtDate(coverage.capture_started_at);
  const lastCapture = fmtDateTime(coverage.last_successful_capture_at);
  return (
    <div className="space-y-1 text-xs text-muted-foreground">
      <p>
        Aluno ativo = sessão, evento de engajamento logado ou mensagem do aluno; captura diária + fontes vivas, dias inteiros
        em horário de Brasília.{" "}
        {captureStart ? `Captura diária desde ${captureStart}` : "Captura diária ainda sem execução registrada"}
        {lastCapture ? `; última coleta ${lastCapture}.` : "."}
      </p>
      <ul className="list-disc pl-4">
        {(Object.keys(SOURCE_LABEL) as (keyof typeof SOURCE_LABEL)[]).map((k) => (
          <li key={k}>
            {sources[k]
              ? `${SOURCE_LABEL[k]}: primeiro registro observado em ${fmtDate(sources[k])} (limite observado, não garantia de completude).`
              : `${SOURCE_LABEL[k]}: sem registro observado.`}
          </li>
        ))}
      </ul>
      <p>{coverage.limitation}</p>
    </div>
  );
}
