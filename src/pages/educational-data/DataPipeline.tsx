// Pipeline de Importação e Normalização de Dados MEC.
//
// Retoma a linguagem visual do painel shadcn que existia antes do #46 (Card +
// CardDescription, caixa Fonte/Destino sobre bg-muted/40, Badge de status) e a
// aplica sobre os controles reais do pipeline: seleção de ciclo, herança,
// disparo, parada e status em tempo real.
//
// Os logs vivem em <EtlProcessingLogs />, irmão desta tela em ProgramsImport —
// não em uma aba interna, para não aninhar abas dentro de abas.
import React, { useState } from "react";
import {
  useActivePrograms,
  useCloneCycle,
  useEtlLogs,
  useStopEtlStep,
  useTriggerEtlStep,
  useUpdatePrevCycle,
} from "@/hooks/useEtlPipeline";
import { EtlStepType, Program } from "@/services/etlPipelineService";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import {
  CheckCircle2,
  ChevronDown,
  Clock,
  Copy,
  Database,
  GraduationCap,
  Loader2,
  Play,
  RefreshCw,
  Square,
  XCircle,
} from "lucide-react";

const NO_PREV_CYCLE = "__none__";

/** <select> nativo com o visual do SelectTrigger do shadcn. */
function NativeSelect({
  id,
  value,
  onChange,
  disabled,
  children,
}: {
  id?: string;
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className="relative">
      <select
        id={id}
        value={value}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
        className="flex h-10 w-full appearance-none items-center justify-between rounded-md border border-input bg-background px-3 py-2 pr-8 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
      >
        {children}
      </select>
      <ChevronDown className="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 opacity-50" />
    </div>
  );
}

function cycleLabel(p: Program) {
  return `${p.title} (${p.cycle_year}.${p.cycle_semester}) — ${p.status}`;
}

function StepStatusBadge({ status, pct }: { status: string | null; pct?: number }) {
  if (status === "success") {
    return (
      <Badge className="shrink-0 gap-1 border-emerald-200 bg-emerald-50 text-emerald-700 hover:bg-emerald-50">
        <CheckCircle2 className="h-3.5 w-3.5" /> Importado
      </Badge>
    );
  }
  if (status === "error") {
    return (
      <Badge className="shrink-0 gap-1 border-red-200 bg-red-50 text-red-700 hover:bg-red-50">
        <XCircle className="h-3.5 w-3.5" /> Erro
      </Badge>
    );
  }
  if (status === "cancelled") {
    return (
      <Badge className="shrink-0 gap-1 border-amber-200 bg-amber-50 text-amber-700 hover:bg-amber-50">
        <XCircle className="h-3.5 w-3.5" /> Cancelado
      </Badge>
    );
  }
  if (status === "running") {
    return (
      <Badge className="shrink-0 animate-pulse gap-1 border-sky-200 bg-sky-50 text-sky-700 hover:bg-sky-50">
        <Loader2 className="h-3.5 w-3.5 animate-spin" /> Rodando{pct !== undefined ? ` ${pct}%` : "..."}
      </Badge>
    );
  }
  return (
    <Badge variant="outline" className="shrink-0 gap-1 text-muted-foreground">
      <Clock className="h-3.5 w-3.5" /> Não executado
    </Badge>
  );
}

/** Caixa de um passo: descrição + Fonte/Destino + status + ação. */
function StepBox({
  title,
  source,
  destination,
  status,
  pct,
  children,
}: {
  title: string;
  source: string;
  destination: string;
  status?: string | null;
  pct?: number;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-3 rounded-md border bg-muted/40 p-4">
      <div className="flex items-start justify-between gap-2">
        <p className="text-sm font-medium leading-tight">{title}</p>
        {status !== undefined && <StepStatusBadge status={status} pct={pct} />}
      </div>
      <div className="flex flex-col gap-0.5 text-xs text-muted-foreground">
        <span>
          <strong className="font-medium text-foreground">Fonte:</strong> {source}
        </span>
        <span>
          <strong className="font-medium text-foreground">Destino:</strong> {destination}
        </span>
      </div>
      {children}
    </div>
  );
}

export default function DataPipeline() {
  const { data: programs, isLoading: isLoadingPrograms } = useActivePrograms();
  const [selectedProuniId, setSelectedProuniId] = useState("");
  const [selectedSisuId, setSelectedSisuId] = useState("");

  const { data: prouniLogs } = useEtlLogs(selectedProuniId || null);
  const { data: sisuLogs } = useEtlLogs(selectedSisuId || null);
  const { data: globalLogs } = useEtlLogs(null);

  const { mutate: triggerStep, isPending } = useTriggerEtlStep();
  const { mutate: updatePrevCycle } = useUpdatePrevCycle();
  const { mutate: cloneCycle, isPending: isCloning } = useCloneCycle();
  const { mutate: stopStep, isPending: isStopping } = useStopEtlStep();

  const [progressMap, setProgressMap] = useState<Record<string, number>>({});
  const [elapsed, setElapsed] = useState(0);

  React.useEffect(() => {
    if (!isPending) {
      setElapsed(0);
      return;
    }
    const interval = setInterval(() => setElapsed((e) => e + 1), 1000);
    return () => clearInterval(interval);
  }, [isPending]);

  const prouniPrograms = programs?.filter((p) => p.type === "prouni") || [];
  const sisuPrograms = programs?.filter((p) => p.type === "sisu") || [];
  const selectedProuni = prouniPrograms.find((p) => p.id === selectedProuniId);

  const statusOf = (step: EtlStepType, logs: any[] | undefined) =>
    logs?.find((l) => l.etl_type === step)?.status ?? null;

  const handlePrevCycleChange = (programId: string, prevProgramId: string) => {
    updatePrevCycle({ programId, prevProgramId: prevProgramId === NO_PREV_CYCLE ? null : prevProgramId });
  };

  const handleClone = () => {
    if (!selectedProuni?.prev_program_id) return;
    if (
      confirm("Deseja clonar os dados do ciclo anterior para este ciclo? Todas as oportunidades e vagas serão copiadas.")
    ) {
      cloneCycle({ sourceProgramId: selectedProuni.prev_program_id, targetProgramId: selectedProuni.id });
    }
  };

  const handleTrigger = (step: EtlStepType, programId: string | null) => {
    if (!programId && !["emec", "refresh_opportunities"].includes(step)) return;
    setProgressMap((prev) => ({ ...prev, [step]: 0 }));
    triggerStep({
      step,
      programId: programId || undefined,
      onProgress: (processed, total) =>
        setProgressMap((prev) => ({ ...prev, [step]: total > 0 ? Math.round((processed / total) * 100) : 0 })),
    });
  };

  /** Botão de disparo que vira "Parar Execução" enquanto o passo roda. */
  const StepAction = ({
    step,
    label,
    programId,
    logs,
  }: {
    step: EtlStepType;
    label: string;
    programId: string | null;
    logs: any[] | undefined;
  }) => {
    const currentLog = logs?.find((l) => l.etl_type === step);
    const pct = progressMap[step];

    if (currentLog?.status === "running" || isPending) {
      return (
        <Button
          variant="destructive"
          className="w-full justify-between"
          onClick={() => currentLog && stopStep({ logId: currentLog.id })}
          disabled={isStopping || !currentLog}
          title="Parar execução"
        >
          <span>
            {isStopping ? "Parando..." : "Parar Execução"}
            {elapsed > 0 && <span className="ml-1.5 text-xs font-normal opacity-80">({elapsed}s)</span>}
            {pct !== undefined && <span className="ml-1.5 font-bold">{pct}%</span>}
          </span>
          {isStopping ? <Loader2 className="h-4 w-4 animate-spin" /> : <Square className="h-4 w-4 fill-current" />}
        </Button>
      );
    }

    return (
      <Button variant="outline" className="w-full justify-between" onClick={() => handleTrigger(step, programId)}>
        <span>{label}</span>
        <Play className="h-4 w-4" />
      </Button>
    );
  };

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-xl font-semibold tracking-tight">Importação de Dados MEC (ETL)</h2>
        <p className="mt-1 max-w-4xl text-sm text-muted-foreground">
          Certifique-se de que o CSV correspondente foi previamente carregado na respectiva tabela{" "}
          <code className="rounded bg-muted px-1 py-0.5 font-mono text-xs">staging</code> via Supabase / DBeaver. Depois,
          selecione o ciclo e dispare a importação para processar os dados e unificá-los ao catálogo do Nubo.
        </p>
      </div>

      <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-4">
        {/* ---------------------------------------------------------------- ProUni */}
        <Card className="flex flex-col">
          <CardHeader className="pb-4">
            <CardTitle className="flex items-center gap-2 text-base">
              <Database className="h-4 w-4 text-sky-600" /> Pipeline ProUni
            </CardTitle>
            <CardDescription>Integração unificada e herança de ciclo.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="prouni-cycle">Selecione o Ciclo (Contexto)</Label>
              <NativeSelect
                id="prouni-cycle"
                value={selectedProuniId}
                onChange={setSelectedProuniId}
                disabled={isLoadingPrograms}
              >
                <option value="">{isLoadingPrograms ? "Carregando ciclos..." : "Escolha um ciclo ProUni"}</option>
                {prouniPrograms.map((p) => (
                  <option key={p.id} value={p.id}>
                    {cycleLabel(p)}
                  </option>
                ))}
              </NativeSelect>
            </div>

            {selectedProuniId && (
              <div className="space-y-2">
                <Label htmlFor="prouni-prev-cycle">Ciclo Anterior (Comparação / Herança)</Label>
                <NativeSelect
                  id="prouni-prev-cycle"
                  value={selectedProuni?.prev_program_id || NO_PREV_CYCLE}
                  onChange={(v) => handlePrevCycleChange(selectedProuniId, v)}
                >
                  <option value={NO_PREV_CYCLE}>Sem ciclo anterior</option>
                  {prouniPrograms
                    .filter((p) => p.id !== selectedProuniId && p.is_fully_imported)
                    .map((p) => (
                      <option key={p.id} value={p.id}>
                        {cycleLabel(p)}
                      </option>
                    ))}
                </NativeSelect>
                <p className="text-xs text-muted-foreground">
                  O ciclo listado acima deve ter completado toda a importação (is_fully_imported).
                </p>
              </div>
            )}

            {selectedProuniId && (
              <>
                <StepBox
                  title="1. Importação Unificada"
                  source="rawprouni"
                  destination="opportunities + opportunities_prouni_vacancies"
                  status={statusOf("prouni_base", prouniLogs)}
                  pct={progressMap["prouni_base"]}
                >
                  <StepAction
                    step="prouni_base"
                    label="Importar Base + Vagas"
                    programId={selectedProuniId}
                    logs={prouniLogs}
                  />
                </StepBox>

                {selectedProuni?.prev_program_id && (
                  <StepBox
                    title="2. Herança (Clonagem)"
                    source="Ciclo anterior selecionado acima"
                    destination="opportunities + opportunities_prouni_vacancies"
                  >
                    <Button
                      variant="outline"
                      className="w-full justify-between"
                      onClick={handleClone}
                      disabled={isCloning}
                    >
                      <span>{isCloning ? "Clonando..." : "Clonar do Ciclo Anterior"}</span>
                      {isCloning ? <Loader2 className="h-4 w-4 animate-spin" /> : <Copy className="h-4 w-4" />}
                    </Button>
                  </StepBox>
                )}
              </>
            )}
          </CardContent>
        </Card>

        {/* ------------------------------------------------------------------ SiSU */}
        <Card className="flex flex-col">
          <CardHeader className="pb-4">
            <CardTitle className="flex items-center gap-2 text-base">
              <GraduationCap className="h-4 w-4 text-emerald-600" /> Pipeline SiSU
            </CardTitle>
            <CardDescription>Integração de base e vagas ofertadas.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="sisu-cycle">Selecione o Ciclo (Contexto)</Label>
              <NativeSelect
                id="sisu-cycle"
                value={selectedSisuId}
                onChange={setSelectedSisuId}
                disabled={isLoadingPrograms}
              >
                <option value="">{isLoadingPrograms ? "Carregando ciclos..." : "Escolha um ciclo SiSU"}</option>
                {sisuPrograms.map((p) => (
                  <option key={p.id} value={p.id}>
                    {cycleLabel(p)}
                  </option>
                ))}
              </NativeSelect>
            </div>

            {selectedSisuId && (
              <div className="space-y-2">
                <Label htmlFor="sisu-prev-cycle">Ciclo Anterior (Comparação Opcional)</Label>
                <NativeSelect
                  id="sisu-prev-cycle"
                  value={sisuPrograms.find((p) => p.id === selectedSisuId)?.prev_program_id || NO_PREV_CYCLE}
                  onChange={(v) => handlePrevCycleChange(selectedSisuId, v)}
                >
                  <option value={NO_PREV_CYCLE}>Sem ciclo anterior (ocultar comparação)</option>
                  {sisuPrograms
                    .filter((p) => p.id !== selectedSisuId && p.is_fully_imported)
                    .map((p) => (
                      <option key={p.id} value={p.id}>
                        {cycleLabel(p)}
                      </option>
                    ))}
                </NativeSelect>
                <p className="text-xs text-muted-foreground">
                  O ciclo listado acima deve ter completado toda a importação (is_fully_imported).
                </p>
              </div>
            )}

            {selectedSisuId && (
              <>
                <StepBox
                  title="1. Vagas Ofertadas (Termo de Adesão)"
                  source="rawsisuvacancies"
                  destination="opportunities_sisu_vacancies"
                  status={statusOf("sisu_vacancies", sisuLogs)}
                  pct={progressMap["sisu_vacancies"]}
                >
                  <StepAction
                    step="sisu_vacancies"
                    label="Importar Termo de Adesão (Vagas)"
                    programId={selectedSisuId}
                    logs={sisuLogs}
                  />
                </StepBox>

                <StepBox
                  title="2. Base Consolidada (Notas de Corte)"
                  source="rawsisu"
                  destination="opportunities"
                  status={statusOf("sisu", sisuLogs)}
                  pct={progressMap["sisu"]}
                >
                  <StepAction
                    step="sisu"
                    label="Importar Base Consolidada"
                    programId={selectedSisuId}
                    logs={sisuLogs}
                  />
                </StepBox>
              </>
            )}
          </CardContent>
        </Card>

        {/* ------------------------------------------------------------------ e-MEC */}
        <Card className="flex flex-col">
          <CardHeader className="pb-4">
            <CardTitle className="flex items-center gap-2 text-base">
              <Database className="h-4 w-4 text-amber-500" /> Pipeline e-MEC
            </CardTitle>
            <CardDescription>Enriquecimento e metadados globais das IES.</CardDescription>
          </CardHeader>
          <CardContent>
            <StepBox
              title="Enriquecimento de IES"
              source="rawemec"
              destination="institutions_info_emec"
              status={statusOf("emec", globalLogs)}
              pct={progressMap["emec"]}
            >
              <StepAction step="emec" label="Importar Metadados" programId={null} logs={globalLogs} />
            </StepBox>
          </CardContent>
        </Card>

        {/* ---------------------------------------------------------- Sincronização */}
        <Card className="flex flex-col">
          <CardHeader className="pb-4">
            <CardTitle className="flex items-center gap-2 text-base">
              <RefreshCw className="h-4 w-4 text-slate-600" /> Sincronização
            </CardTitle>
            <CardDescription>Atualização das views materializadas. Rode ao final das importações.</CardDescription>
          </CardHeader>
          <CardContent>
            <StepBox
              title="Oportunidades"
              source="opportunities + partner_opportunities"
              destination="v_unified_opportunities"
              status={statusOf("refresh_opportunities", globalLogs)}
              pct={progressMap["refresh_opportunities"]}
            >
              <StepAction
                step="refresh_opportunities"
                label="Atualizar"
                programId={null}
                logs={globalLogs}
              />
            </StepBox>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
