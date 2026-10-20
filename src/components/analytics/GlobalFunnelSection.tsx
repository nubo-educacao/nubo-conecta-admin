import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Skeleton } from "@/components/ui/skeleton";
import {
  FunnelChart,
  type FunnelChartStep,
} from "@/components/analytics/FunnelChart";
import {
  fetchGlobalFunnel,
  productAnalyticsKeys,
} from "@/services/productAnalyticsService";
import type { AttributionFilter } from "@/lib/attributionFilter";
import type {
  DomainFunnel,
  FunnelStepKey,
  GlobalFunnel,
  InstrumentationCoverage,
} from "@/types/productAnalytics";

export interface GlobalFunnelSectionProps {
  /** null = todo o período. */
  range: { from: Date; to: Date } | null;
  attribution?: AttributionFilter;
}

type Unit = "events" | "people";
type Availability = "complete" | "partial" | "unavailable";

const MEC_COLOR = "#3092bb"; // nubo primary
const PARTNER_COLOR = "#024F86"; // nubo primary-dark
const HATCH =
  "repeating-linear-gradient(135deg, transparent, transparent 5px, rgba(0,0,0,.25) 5px, rgba(0,0,0,.25) 7px)";
const NOT_BY_SURFACE = "não instrumentado por superfície";
const STEP_ORDER: FunnelStepKey[] = ["card_view", "card_click", "terminal"];

// FunnelChart (contrato congelado do TP-D) pinta as barras com `bg-nubo-primary` e
// `bg-nubo-primary-dark`, classes que não existem no tailwind.config. Sem alterar o
// chart, o escopo abaixo dá a elas as cores do design: MEC = primary, Parceiro = primary-dark.
const MEC_CHART_SCOPE =
  "[&_.bg-nubo-primary]:bg-[#3092bb] [&_.bg-nubo-primary-dark]:bg-[#024F86]";
const PARTNER_CHART_SCOPE =
  "[&_.bg-nubo-primary]:bg-[#024F86] [&_.bg-nubo-primary-dark]:bg-[#024F86]";

const fmt = (n: number) => n.toLocaleString("pt-BR");
const fmtDate = (iso?: string | null) =>
  iso
    ? new Date(iso).toLocaleDateString("pt-BR", {
        timeZone: "America/Sao_Paulo",
      })
    : null;

function availabilityOf(coverage?: InstrumentationCoverage): Availability {
  if (!coverage) return "complete";
  if (coverage.status === "unknown" || coverage.status === "not_instrumented")
    return "unavailable";
  return coverage.status === "partial" ? "partial" : "complete";
}

/** Texto de cobertura (D-m). `first_observed_at` nunca vira data de implantação. */
function coverageNote(
  label: string,
  coverage?: InstrumentationCoverage,
): string | null {
  if (!coverage) return null;
  const verified = fmtDate(coverage.verified_since);
  const firstSeen = fmtDate(coverage.first_observed_at);
  switch (coverage.status) {
    case "not_instrumented": {
      const before = verified ?? fmtDate(coverage.capture_started_at);
      return before
        ? `${label}: não instrumentado antes de ${before}.`
        : `${label}: não instrumentado no período.`;
    }
    case "partial":
      return `${label}: janela parcial${verified ? ` (verificado desde ${verified})` : ""} — valores observados, sem razão completa.`;
    case "unknown":
      return firstSeen
        ? `${label}: cobertura desconhecida — primeiro evento observado em ${firstSeen}.`
        : `${label}: cobertura desconhecida — ainda sem eventos observados.`;
    default:
      return null;
  }
}

function partText(n: number, availability: Availability): string {
  if (availability === "unavailable")
    return n === 0 ? "indisponível" : `${fmt(n)} (observados, cobertura incompleta)`;
  return availability === "partial" ? `${fmt(n)} (janela parcial)` : fmt(n);
}

/** Valor para o chart: indisponível sem eventos é ausência (null), nunca zero medido. */
function chartValue(n: number, availability: Availability): number | null {
  return availability === "unavailable" && n === 0 ? null : n;
}

function Swatch({ color, hatched }: { color: string; hatched?: boolean }) {
  return (
    <span
      aria-hidden="true"
      className="inline-block h-3 w-3 rounded-sm border border-slate-300"
      style={{
        backgroundColor: hatched ? "transparent" : color,
        backgroundImage: hatched ? HATCH : undefined,
      }}
    />
  );
}

function incompleteLabel(
  mec: Availability,
  partner: Availability,
): string | null {
  const parts = [
    mec !== "complete" ? `MEC ${mec === "partial" ? "parcial" : "indisponível"}` : null,
    partner !== "complete"
      ? `Parceiro ${partner === "partial" ? "parcial" : "indisponível"}`
      : null,
  ].filter(Boolean);
  return parts.length ? parts.join(" e ") : null;
}

function EventsRow({
  data,
  stepKey,
  maxTotal,
}: {
  data: GlobalFunnel;
  stepKey: FunnelStepKey;
  maxTotal: number;
}) {
  const total = data.totals_by_step.find((t) => t.key === stepKey);
  const mec = data.domains.mec.steps.find((s) => s.key === stepKey);
  const partner = data.domains.partner.steps.find((s) => s.key === stepKey);
  if (!total || !mec || !partner) return null;
  const mecAv = availabilityOf(mec.coverage);
  const partnerAv = availabilityOf(partner.coverage);
  const incomplete = incompleteLabel(mecAv, partnerAv);
  // Só eventos disjuntos podem ser empilhados.
  const stacked = mec.events + partner.events === total.events;
  const barWidth = maxTotal > 0 ? (total.events / maxTotal) * 100 : 0;
  const parts = [
    { name: "MEC", value: mec.events, av: mecAv, color: MEC_COLOR },
    { name: "Parceiro", value: partner.events, av: partnerAv, color: PARTNER_COLOR },
  ];
  return (
    <div data-testid="global-step" data-step={stepKey} className="space-y-1">
      <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm">
        <span className="font-medium">{mec.label}</span>
        <span className="text-right">
          <span data-testid="step-total" className="font-semibold">
            {fmt(total.events)}
          </span>{" "}
          <span className="text-xs text-muted-foreground">
            {incomplete
              ? `soma das parcelas observadas (${incomplete})`
              : "Total"}
          </span>
        </span>
      </div>
      <div
        role="img"
        aria-label={`${mec.label}: ${fmt(total.events)} eventos${incomplete ? ` observados (${incomplete})` : ""}; ${parts
          .map((p) => `${p.name} ${partText(p.value, p.av)}`)
          .join("; ")}`}
        className="h-8 overflow-hidden rounded bg-slate-100"
      >
        <div className="flex h-full" style={{ width: `${barWidth}%` }}>
          {stacked ? (
            parts
              .filter((p) => p.value > 0)
              .map((p) => (
                <div
                  key={p.name}
                  title={`${p.name}: ${p.value}`}
                  className="h-full"
                  style={{
                    width: `${(p.value / total.events) * 100}%`,
                    backgroundColor: p.color,
                    backgroundImage: p.av !== "complete" ? HATCH : undefined,
                  }}
                />
              ))
          ) : (
            <div className="h-full w-full" style={{ backgroundColor: MEC_COLOR }} />
          )}
        </div>
      </div>
      <ul className="flex flex-wrap gap-x-4 gap-y-1 text-xs">
        {parts.map((p) => (
          <li key={p.name} className="inline-flex items-center gap-1.5">
            <Swatch color={p.color} hatched={p.av === "unavailable" && p.value === 0} />
            <span>{`${p.name}: ${partText(p.value, p.av)}`}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function PeopleRow({
  data,
  stepKey,
  maxPeople,
}: {
  data: GlobalFunnel;
  stepKey: FunnelStepKey;
  maxPeople: number;
}) {
  const total = data.totals_by_step.find((t) => t.key === stepKey);
  const mec = data.domains.mec.steps.find((s) => s.key === stepKey);
  const partner = data.domains.partner.steps.find((s) => s.key === stepKey);
  if (!total || !mec || !partner) return null;
  const mecAv = availabilityOf(mec.coverage);
  const partnerAv = availabilityOf(partner.coverage);
  const incomplete = incompleteLabel(mecAv, partnerAv);
  const sides = [
    { name: "MEC", value: mec.users, av: mecAv, color: MEC_COLOR },
    { name: "Parceiro", value: partner.users, av: partnerAv, color: PARTNER_COLOR },
  ];
  return (
    <div data-testid="global-step" data-step={stepKey} className="space-y-1">
      <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm">
        <span className="font-medium">{mec.label}</span>
        <span className="text-right">
          <span data-testid="step-total" className="font-semibold">
            {fmt(total.distinct_identities)}
          </span>{" "}
          <span className="text-xs text-muted-foreground">
            {incomplete
              ? `pessoas distintas observadas (${incomplete})`
              : "pessoas distintas (união calculada no servidor)"}
          </span>
        </span>
      </div>
      {/* Lado a lado: a mesma identidade pode estar nos dois domínios. */}
      {sides.map((side) => (
        <div key={side.name} className="flex items-center gap-2 text-xs">
          <span className="w-16 shrink-0">{side.name}</span>
          <div
            role="img"
            aria-label={`${side.name}: ${partText(side.value, side.av)} pessoas`}
            className="h-4 flex-1 overflow-hidden rounded bg-slate-100"
          >
            <div
              className="h-full"
              style={{
                width: `${maxPeople > 0 ? (side.value / maxPeople) * 100 : 0}%`,
                backgroundColor: side.color,
                backgroundImage: side.av !== "complete" ? HATCH : undefined,
              }}
            />
          </div>
          <span>{`${side.name}: ${partText(side.value, side.av)}`}</span>
        </div>
      ))}
      <p className="text-xs text-muted-foreground">
        Soma de contagens por domínio: {fmt(total.domain_identity_sum)} — não é
        total de pessoas únicas (a mesma identidade pode estar nos dois
        domínios).
      </p>
    </div>
  );
}

function chartSteps(domain: DomainFunnel, unit: Unit): FunnelChartStep[] {
  return STEP_ORDER.flatMap((key) => {
    const step = domain.steps.find((s) => s.key === key);
    if (!step) return [];
    const raw = unit === "events" ? step.events : step.users;
    const composition =
      unit === "events" && key === "terminal" && domain.composition_events
        ? [
            { label: "Redirecionadas", value: domain.composition_events.redirected },
            { label: "Enviadas", value: domain.composition_events.submitted },
            {
              label: "Legado v0 (redirect externo)",
              value: domain.composition_events.legacy_external_redirect,
            },
          ]
        : undefined;
    return [
      {
        key: step.key,
        label: step.label,
        value: chartValue(raw, availabilityOf(step.coverage)),
        coverage: step.coverage,
        notInstrumented: step.coverage.status === "not_instrumented" || undefined,
        composition,
      },
    ];
  });
}

function DomainPanel({
  testId,
  title,
  note,
  domain,
  unit,
  scope,
}: {
  testId: string;
  title: string;
  note?: string;
  domain: DomainFunnel;
  unit: Unit;
  scope: string;
}) {
  return (
    <section data-testid={testId} className="space-y-2" aria-label={title}>
      <h4 className="text-sm font-semibold">{title}</h4>
      {note && <p className="text-xs text-muted-foreground">{note}</p>}
      <div className={scope}>
        <FunnelChart
          mode="observed_volumes"
          unitLabel={unit === "events" ? "eventos" : "pessoas"}
          steps={chartSteps(domain, unit)}
          emptyLabel="Sem dados observados"
        />
      </div>
    </section>
  );
}

function clicksCell(row: GlobalFunnel["by_surface"][number]): string {
  if (row.surface === NOT_BY_SURFACE) return fmt(row.clicks);
  const availability = availabilityOf(row.coverage);
  if (availability === "unavailable")
    return row.clicks === 0 ? "não instrumentado" : `${fmt(row.clicks)} (observados, cobertura incompleta)`;
  return availability === "partial" ? `${fmt(row.clicks)} (janela parcial)` : fmt(row.clicks);
}

function SurfaceTable({ rows }: { rows: GlobalFunnel["by_surface"] }) {
  if (!rows.length)
    return (
      <p className="text-sm text-muted-foreground">
        Nenhuma superfície com eventos no período.
      </p>
    );
  return (
    <div className="overflow-x-auto">
      <table
        aria-label="Views e cliques por superfície e domínio"
        className="w-full text-left text-sm"
      >
        <thead>
          <tr className="border-b text-xs text-muted-foreground">
            <th scope="col" className="py-1 pr-3 font-medium">Superfície</th>
            <th scope="col" className="py-1 pr-3 font-medium">Domínio</th>
            <th scope="col" className="py-1 pr-3 text-right font-medium">Views</th>
            <th scope="col" className="py-1 text-right font-medium">Cliques</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => {
            const bySurface = row.surface !== NOT_BY_SURFACE;
            return (
              <tr key={`${row.domain}-${row.surface}-${i}`} className="border-b last:border-0">
                <td className="py-1 pr-3">
                  {row.surface === null ? (
                    <span className="text-muted-foreground">(sem superfície)</span>
                  ) : bySurface ? (
                    <>
                      <code className="text-xs">{row.surface}</code>
                      {row.surface === "oportunidades_lista" && (
                        <span className="block text-xs text-muted-foreground">
                          histórico = aba "Para Você"
                        </span>
                      )}
                    </>
                  ) : (
                    <span>Não instrumentado por superfície</span>
                  )}
                </td>
                <td className="py-1 pr-3">{row.domain === "mec" ? "MEC" : "Parceiro"}</td>
                <td className="py-1 pr-3 text-right">{bySurface ? fmt(row.views) : "—"}</td>
                <td className="py-1 text-right">{clicksCell(row)}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function periodText(period: GlobalFunnel["period"]): string {
  const from = fmtDate(period.from);
  const to = fmtDate(period.to);
  return from ? `${from} a ${to}` : `início dos registros a ${to}`;
}

function Body({ data }: { data: GlobalFunnel }) {
  const [unit, setUnit] = useState<Unit>("events");
  const { mec, partner } = data.domains;
  const empty = data.totals_by_step.every(
    (t) => t.events === 0 && t.distinct_identities === 0,
  );
  const maxEvents = Math.max(0, ...data.totals_by_step.map((t) => t.events));
  const maxPeople = Math.max(0, ...data.totals_by_step.map((t) => t.distinct_identities));
  const terminalMec = mec.steps.find((s) => s.key === "terminal");
  const clickCoverage = data.by_surface[0]?.coverage;
  const notes = [
    coverageNote("Encaminhamento MEC (redirect oficial)", terminalMec?.coverage),
    coverageNote("Cliques por superfície", clickCoverage),
  ].filter((n): n is string => n !== null);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-muted-foreground">
          Período: {periodText(data.period)}
        </p>
        <div role="group" aria-label="Unidade" className="inline-flex overflow-hidden rounded-md border text-sm">
          {(["events", "people"] as const).map((u) => (
            <button
              key={u}
              type="button"
              aria-pressed={unit === u}
              onClick={() => setUnit(u)}
              className={
                unit === u
                  ? "bg-primary px-3 py-1 text-primary-foreground"
                  : "px-3 py-1 hover:bg-muted"
              }
            >
              {u === "events" ? "Eventos" : "Pessoas"}
            </button>
          ))}
        </div>
      </div>

      <div className="space-y-1 text-xs text-muted-foreground">
        <p>
          {unit === "events"
            ? "Unidade: eventos (soma de event_count). Barras empilhadas por domínio."
            : "Unidade: identidades distintas observadas (user:/anon:), sem deduplicar visitante anônimo e login posterior."}
        </p>
        <p>
          Atenção: pessoas não são aditivas entre etapas nem entre domínios.
        </p>
        <p>{data.unit_note}</p>
      </div>

      {empty ? (
        <p className="text-sm text-muted-foreground">
          Nenhum evento observado neste período.
        </p>
      ) : (
        <div data-testid="global-funnel" className="space-y-4">
          {STEP_ORDER.map((key) =>
            unit === "events" ? (
              <EventsRow key={key} data={data} stepKey={key} maxTotal={maxEvents} />
            ) : (
              <PeopleRow key={key} data={data} stepKey={key} maxPeople={maxPeople} />
            ),
          )}
        </div>
      )}

      {notes.length > 0 && (
        <ul data-testid="coverage-notes" className="list-disc space-y-1 pl-5 text-xs">
          {notes.map((n) => (
            <li key={n}>{n}</li>
          ))}
        </ul>
      )}

      {!empty && (
        <div className="space-y-3">
          <p className="text-xs text-muted-foreground">
            Razões são calculadas dentro de cada domínio. São razões de volumes
            observados, não conversão de coorte, e podem passar de 100%.
          </p>
          <div className="grid gap-6 md:grid-cols-2">
            <DomainPanel
              testId="domain-mec"
              title="MEC"
              domain={mec}
              unit={unit}
              scope={MEC_CHART_SCOPE}
              note="Encaminhamento = redirect oficial para o site do MEC."
            />
            <DomainPanel
              testId="domain-partner"
              title="Parceiro"
              domain={partner}
              unit={unit}
              scope={PARTNER_CHART_SCOPE}
              note="Encaminhamento = candidatura redirecionada ou enviada, mais o legado v0; o redirect partner_application não é somado de novo."
            />
          </div>
        </div>
      )}

      <div className="space-y-2">
        <h4 className="text-sm font-semibold">Jornada por superfície</h4>
        <SurfaceTable rows={data.by_surface} />
        <p className="text-xs text-muted-foreground">
          Cliques anteriores ao NUB-RD-96 não registram a superfície e aparecem
          como "não instrumentado por superfície". Em oportunidades_lista, o
          histórico corresponde à aba "Para Você".
        </p>
      </div>
    </div>
  );
}

export function GlobalFunnelSection({ range, attribution }: GlobalFunnelSectionProps) {
  const period = range ?? undefined;
  const { data, isLoading, error } = useQuery({
    queryKey: productAnalyticsKeys.global(period, attribution),
    queryFn: () => fetchGlobalFunnel(period, attribution),
    staleTime: 1000 * 60 * 5,
    throwOnError: false,
  });
  const hasBase =
    !!data?.domains?.mec && !!data.domains.partner && data.totals_by_step?.length > 0;

  return (
    <div className="chart-container" data-testid="global-funnel-section">
      <h3 className="font-display text-lg font-semibold">Funil global: MEC e Parceiro</h3>
      <p className="mb-6 text-sm text-muted-foreground">
        Visualizações → cliques → encaminhamentos no período selecionado.
      </p>
      {isLoading ? (
        <div role="status" aria-label="Carregando funil global">
          <Skeleton className="h-[320px] w-full" />
        </div>
      ) : error ? (
        <p role="alert" className="text-sm text-muted-foreground">
          Não foi possível carregar o funil global. Tente novamente em instantes.
        </p>
      ) : !data || !hasBase ? (
        <p className="text-sm text-muted-foreground">
          Sem base de dados do funil para este período. Isso não significa zero eventos.
        </p>
      ) : (
        <Body data={data} />
      )}
    </div>
  );
}
