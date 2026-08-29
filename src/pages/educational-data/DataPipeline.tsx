import React, { useState } from "react";
import {
  useActivePrograms,
  useEtlLogs,
  useTriggerEtlStep,
  useUpdatePrevCycle,
  useCloneCycle,
  useStopEtlStep,
  useAllEtlLogs,
  useRollbackEtlStep,
} from "@/hooks/useEtlPipeline";
import { EtlStepType } from "@/services/etlPipelineService";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Skeleton } from "@/components/ui/skeleton";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import {
  Database,
  Play,
  CheckCircle2,
  CheckCircle,
  XCircle,
  AlertCircle,
  Clock,
  Loader2,
  Loader,
  Square,
  Undo2,
  ChevronLeft,
  ChevronRight,
  RefreshCw,
} from "lucide-react";

export default function DataPipeline() {
  // States for Pipeline Control
  const { data: programs, isLoading: isLoadingPrograms } = useActivePrograms();
  const [selectedProuniId, setSelectedProuniId] = useState<string | null>(null);
  const [selectedSisuId, setSelectedSisuId] = useState<string | null>(null);

  const { data: prouniLogs } = useEtlLogs(selectedProuniId);
  const { data: sisuLogs } = useEtlLogs(selectedSisuId);
  const { data: globalLogs } = useEtlLogs(null);

  const { mutate: triggerStep, isPending } = useTriggerEtlStep();
  const { mutate: updatePrevCycle } = useUpdatePrevCycle();
  const { mutate: cloneCycle, isPending: isCloning } = useCloneCycle();
  const { mutate: stopStep, isPending: isStopping, variables: stopVars } = useStopEtlStep();

  // States for Logs Tab
  const [logsPage, setLogsPage] = useState(0);
  const logsPageSize = 20;
  const { data: logsData, isLoading: isLoadingLogs } = useAllEtlLogs(logsPage, logsPageSize);
  const logs = logsData?.data || [];
  const logsCount = logsData?.count || 0;

  const { mutate: rollbackStep, isPending: isRollingBack, variables: rollbackVars, rollbackProgress } = useRollbackEtlStep();

  // Progress map for active ETL steps
  const [progressMap, setProgressMap] = useState<Record<string, { pct: number }>>({});
  const [elapsed, setElapsed] = useState(0);

  React.useEffect(() => {
    let interval: NodeJS.Timeout;
    if (isPending) {
      interval = setInterval(() => setElapsed((e) => e + 1), 1000);
    } else {
      setElapsed(0);
    }
    return () => clearInterval(interval);
  }, [isPending]);

  const handlePrevCycleChange = (programId: string, prevProgramId: string) => {
    updatePrevCycle({ programId, prevProgramId: prevProgramId || null });
  };

  const handleClone = (targetProgramId: string) => {
    const program = programs?.find((p) => p.id === targetProgramId);
    if (!program || !program.prev_program_id) return;

    if (confirm(`Deseja clonar os dados do ciclo anterior para este ciclo? Todas as oportunidades e vagas serão copiadas.`)) {
      cloneCycle({ sourceProgramId: program.prev_program_id, targetProgramId });
    }
  };

  const handleTrigger = (step: EtlStepType, programId: string | null) => {
    if (!programId && !["emec", "refresh_opportunities"].includes(step)) return;

    setProgressMap((prev) => ({ ...prev, [step]: { pct: 0 } }));

    triggerStep({
      step,
      programId: programId || undefined,
      onProgress: (processed, total) => {
        const pct = total > 0 ? Math.round((processed / total) * 100) : 0;
        setProgressMap((prev) => ({ ...prev, [step]: { pct } }));
      },
    });
  };

  const getStepStatus = (step: EtlStepType, stepLogs: any[] | undefined) => {
    if (!stepLogs) return null;
    return stepLogs.find((l) => l.etl_type === step)?.status || null;
  };

  const renderStatusBadge = (step: EtlStepType, stepLogs: any[] | undefined) => {
    const status = getStepStatus(step, stepLogs);
    if (status === "success")
      return (
        <span className="flex items-center text-emerald-600 text-xs font-semibold">
          <CheckCircle2 className="w-3.5 h-3.5 mr-1" /> Importado
        </span>
      );
    if (status === "error")
      return (
        <span className="flex items-center text-red-600 text-xs font-semibold">
          <XCircle className="w-3.5 h-3.5 mr-1" /> Erro
        </span>
      );
    if (status === "cancelled")
      return (
        <span className="flex items-center text-amber-600 text-xs font-semibold">
          <XCircle className="w-3.5 h-3.5 mr-1" /> Cancelado
        </span>
      );
    if (status === "running") {
      const prog = progressMap[step];
      const displayPct = prog ? ` ${prog.pct}%` : "";
      return (
        <span className="flex items-center text-blue-600 text-xs font-semibold animate-pulse">
          <Loader2 className="w-3.5 h-3.5 mr-1 animate-spin" /> Rodando...{displayPct}
        </span>
      );
    }
    return (
      <span className="flex items-center text-slate-400 text-xs font-medium">
        <Clock className="w-3.5 h-3.5 mr-1" /> Não executado
      </span>
    );
  };

  const renderButton = (
    step: EtlStepType,
    label: string,
    disabled: boolean,
    programId: string | null,
    stepLogs: any[] | undefined
  ) => {
    const currentLog = stepLogs?.find((l) => l.etl_type === step);
    const status = currentLog?.status;
    const isRunning = status === "running" || isPending;

    if (isRunning) {
      return (
        <button
          onClick={() => currentLog && stopStep({ logId: currentLog.id })}
          disabled={isStopping}
          className="flex items-center justify-between w-full px-3 py-2.5 rounded-lg border text-xs font-medium transition-colors mt-2 bg-red-50 border-red-200 text-red-700 hover:bg-red-100 hover:border-red-300"
          title="Parar execução"
        >
          <span className="flex items-center">
            {isStopping ? "Parando..." : "Parar Execução"}
            {elapsed > 0 && <span className="ml-1.5 text-[11px] font-normal opacity-70">({elapsed}s)</span>}
            {progressMap[step] !== undefined && (
              <span className="ml-1.5 font-bold text-red-600">{progressMap[step].pct}%</span>
            )}
          </span>
          {isStopping ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Square className="w-3.5 h-3.5 fill-current" />}
        </button>
      );
    }

    return (
      <button
        onClick={() => handleTrigger(step, programId)}
        disabled={disabled}
        className={`flex items-center justify-between w-full px-3 py-2.5 rounded-lg border text-xs font-medium transition-colors mt-2 ${
          disabled
            ? "bg-slate-50 border-slate-200 text-slate-400 cursor-not-allowed"
            : "bg-white border-sky-200 text-sky-700 hover:bg-sky-50 hover:border-sky-300"
        }`}
      >
        <span className="flex items-center">{label}</span>
        <Play className="w-3.5 h-3.5" />
      </button>
    );
  };

  const prouniPrograms = programs?.filter((p) => p.type === "prouni") || [];
  const sisuPrograms = programs?.filter((p) => p.type === "sisu") || [];

  const typeLabels: Record<string, string> = {
    sisu: "Base SiSU",
    sisu_vacancies: "Vagas SiSU",
    prouni_base: "Base ProUni",
    prouni_vacancies: "Vagas ProUni (Legado)",
    prouni_occupied: "Ocupação ProUni (Legado)",
    emec: "e-MEC",
    refresh_opportunities: "Sincronização Opportunities",
    rollback_sisu: "Base SiSU (Rollback)",
    rollback_sisu_vacancies: "Vagas SiSU (Rollback)",
    rollback_prouni_base: "Base ProUni (Rollback)",
    rollback_prouni_vacancies: "Vagas ProUni (Rollback)",
    rollback_prouni_occupied: "Ocupação ProUni (Rollback)",
  };

  return (
    <div className="w-full space-y-6">
      {/* Header Banner */}
      <div>
        <h1 className="text-2xl font-bold tracking-tight text-slate-900">Importação de Dados MEC (ETL)</h1>
        <p className="mt-1 text-sm text-slate-600 max-w-4xl">
          Instruções operacionais: Certifique-se de que o CSV correspondente foi previamente carregado na sua respectiva tabela{" "}
          <code className="bg-slate-100 px-1 py-0.5 rounded text-slate-800 font-mono text-xs">staging</code> no banco de dados via Supabase / DBeaver. Após o upload, selecione o ciclo abaixo e clique em importar para processar os dados e unificá-los ao catálogo do Nubo.
        </p>
      </div>

      {/* Tabs */}
      <Tabs defaultValue="pipeline" className="w-full">
        <TabsList className="grid w-full grid-cols-2 max-w-md">
          <TabsTrigger value="pipeline" className="flex items-center gap-2">
            <Database className="w-4 h-4" /> Importações (ETL)
          </TabsTrigger>
          <TabsTrigger value="logs" className="flex items-center gap-2">
            <Clock className="w-4 h-4" /> Logs de Processamento
          </TabsTrigger>
        </TabsList>

        {/* Tab 1: Pipelines */}
        <TabsContent value="pipeline" className="mt-6 space-y-6">
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-5 items-start">
            {/* PROUNI PIPELINE */}
            <div className="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-5">
              <div className="border-b border-slate-100 pb-3">
                <h3 className="text-base font-bold text-slate-900 flex items-center">
                  <Database className="w-4 h-4 mr-2 text-sky-600" />
                  Pipeline ProUni
                </h3>
                <p className="text-xs text-slate-500 mt-0.5">Integração Unificada e Herança.</p>
              </div>

              <div className="space-y-1.5">
                <label className="text-xs font-semibold text-slate-700">Selecione o Ciclo (Contexto)</label>
                <select
                  value={selectedProuniId || ""}
                  onChange={(e) => setSelectedProuniId(e.target.value)}
                  disabled={isLoadingPrograms}
                  className="w-full border border-slate-300 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus:ring-2 focus:ring-sky-500 bg-white disabled:bg-slate-50 disabled:text-slate-400"
                >
                  <option value="">{isLoadingPrograms ? "Carregando ciclos..." : "-- Escolha um ciclo ProUni --"}</option>
                  {prouniPrograms.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.title} ({p.cycle_year}.{p.cycle_semester}) - {p.status}
                    </option>
                  ))}
                </select>
              </div>

              {selectedProuniId && (
                <div className="space-y-1.5">
                  <label className="text-xs font-semibold text-slate-700">Ciclo Anterior (Comparação / Herança)</label>
                  <select
                    value={prouniPrograms.find((p) => p.id === selectedProuniId)?.prev_program_id || ""}
                    onChange={(e) => handlePrevCycleChange(selectedProuniId, e.target.value)}
                    className="w-full border border-slate-300 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus:ring-2 focus:ring-sky-500 bg-white"
                  >
                    <option value="">-- Sem ciclo anterior --</option>
                    {prouniPrograms
                      .filter((p) => p.id !== selectedProuniId && p.is_fully_imported)
                      .map((p) => (
                        <option key={p.id} value={p.id}>
                          {p.title} ({p.cycle_year}.{p.cycle_semester}) - {p.status}
                        </option>
                      ))}
                  </select>
                </div>
              )}

              {selectedProuniId && (
                <div className="space-y-3 pt-2">
                  <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                    <div className="flex justify-between items-start mb-1">
                      <div>
                        <span className="text-xs font-semibold text-slate-800">1. Importação Unificada</span>
                        <p className="text-[11px] text-slate-500 font-mono mt-0.5">Tabela: rawprouni</p>
                      </div>
                      {renderStatusBadge("prouni_base", prouniLogs)}
                    </div>
                    {renderButton("prouni_base", "Importar Base + Vagas", false, selectedProuniId, prouniLogs)}
                  </div>

                  {prouniPrograms.find((p) => p.id === selectedProuniId)?.prev_program_id && (
                    <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                      <div className="flex justify-between items-start mb-1">
                        <div>
                          <span className="text-xs font-semibold text-slate-800">2. Herança (Clonagem)</span>
                          <p className="text-[11px] text-slate-500 mt-0.5">Copia vagas e oportunidades do ciclo anterior.</p>
                        </div>
                      </div>
                      <button
                        onClick={() => handleClone(selectedProuniId)}
                        disabled={isCloning}
                        className={`flex items-center justify-between w-full px-3 py-2.5 rounded-lg border text-xs font-medium transition-colors mt-2 ${
                          isCloning
                            ? "bg-slate-50 border-slate-200 text-slate-400 cursor-not-allowed"
                            : "bg-white border-sky-200 text-sky-700 hover:bg-sky-50 hover:border-sky-300"
                        }`}
                      >
                        <span className="flex items-center">{isCloning ? "Clonando..." : "Clonar do Ciclo Anterior"}</span>
                        {isCloning ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Play className="w-3.5 h-3.5" />}
                      </button>
                    </div>
                  )}
                </div>
              )}
            </div>

            {/* SISU PIPELINE */}
            <div className="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-5">
              <div className="border-b border-slate-100 pb-3">
                <h3 className="text-base font-bold text-slate-900 flex items-center">
                  <Database className="w-4 h-4 mr-2 text-emerald-600" />
                  Pipeline SiSU
                </h3>
                <p className="text-xs text-slate-500 mt-0.5">Integração de Base e Vagas.</p>
              </div>

              <div className="space-y-1.5">
                <label className="text-xs font-semibold text-slate-700">Selecione o Ciclo (Contexto)</label>
                <select
                  value={selectedSisuId || ""}
                  onChange={(e) => setSelectedSisuId(e.target.value)}
                  disabled={isLoadingPrograms}
                  className="w-full border border-slate-300 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus:ring-2 focus:ring-emerald-500 bg-white disabled:bg-slate-50 disabled:text-slate-400"
                >
                  <option value="">{isLoadingPrograms ? "Carregando ciclos..." : "-- Escolha um ciclo SiSU --"}</option>
                  {sisuPrograms.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.title} ({p.cycle_year}.{p.cycle_semester}) - {p.status}
                    </option>
                  ))}
                </select>
              </div>

              {selectedSisuId && (
                <div className="space-y-1.5">
                  <label className="text-xs font-semibold text-slate-700">Ciclo Anterior (Comparação Opcional)</label>
                  <select
                    value={sisuPrograms.find((p) => p.id === selectedSisuId)?.prev_program_id || ""}
                    onChange={(e) => handlePrevCycleChange(selectedSisuId, e.target.value)}
                    className="w-full border border-slate-300 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus:ring-2 focus:ring-emerald-500 bg-white"
                  >
                    <option value="">-- Sem ciclo anterior (ocultar comparação) --</option>
                    {sisuPrograms
                      .filter((p) => p.id !== selectedSisuId && p.is_fully_imported)
                      .map((p) => (
                        <option key={p.id} value={p.id}>
                          {p.title} ({p.cycle_year}.{p.cycle_semester}) - {p.status}
                        </option>
                      ))}
                  </select>
                  <p className="text-[11px] text-slate-500">
                    O ciclo listado acima deve ter completado toda a importação (is_fully_imported).
                  </p>
                </div>
              )}

              {selectedSisuId && (
                <div className="space-y-3 pt-2">
                  <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                    <div className="flex justify-between items-start mb-1">
                      <div>
                        <span className="text-xs font-semibold text-slate-800">1. Vagas Ofertadas (Termo de Adesão)</span>
                        <p className="text-[11px] text-slate-500 font-mono mt-0.5">Tabela: rawsisuvacancies</p>
                      </div>
                      {renderStatusBadge("sisu_vacancies", sisuLogs)}
                    </div>
                    {renderButton("sisu_vacancies", "Importar Termo de Adesão (Vagas)", false, selectedSisuId, sisuLogs)}
                  </div>

                  <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                    <div className="flex justify-between items-start mb-1">
                      <div>
                        <span className="text-xs font-semibold text-slate-800">2. Base Consolidada (Notas de Corte)</span>
                        <p className="text-[11px] text-slate-500 font-mono mt-0.5">Tabela: rawsisu</p>
                      </div>
                      {renderStatusBadge("sisu", sisuLogs)}
                    </div>
                    {renderButton("sisu", "Importar Base Consolidada", false, selectedSisuId, sisuLogs)}
                  </div>
                </div>
              )}
            </div>

            {/* EMEC PIPELINE */}
            <div className="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-5">
              <div className="border-b border-slate-100 pb-3">
                <h3 className="text-base font-bold text-slate-900 flex items-center">
                  <Database className="w-4 h-4 mr-2 text-amber-500" />
                  Pipeline e-MEC
                </h3>
                <p className="text-xs text-slate-500 mt-0.5">Enriquecimento e metadados globais.</p>
              </div>

              <div className="space-y-3 pt-2">
                <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                  <div className="flex justify-between items-start mb-1">
                    <div>
                      <span className="text-xs font-semibold text-slate-800">Enriquecimento de IES</span>
                      <p className="text-[11px] text-slate-500 font-mono mt-0.5">Tabela: rawemec</p>
                    </div>
                    {renderStatusBadge("emec", globalLogs)}
                  </div>
                  {renderButton("emec", "Importar Metadados", false, null, globalLogs)}
                </div>
              </div>
            </div>

            {/* SYNC PIPELINE */}
            <div className="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-5">
              <div className="border-b border-slate-100 pb-3">
                <h3 className="text-base font-bold text-slate-900 flex items-center">
                  <RefreshCw className="w-4 h-4 mr-2 text-slate-600" />
                  Sincronização
                </h3>
                <p className="text-xs text-slate-500 mt-0.5">
                  Atualização das views materializadas. Rode ao final das importações.
                </p>
              </div>

              <div className="space-y-3 pt-2">
                <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                  <div className="flex justify-between items-start mb-1">
                    <div>
                      <span className="text-xs font-semibold text-slate-800">Oportunidades</span>
                      <p className="text-[11px] text-slate-500 font-mono mt-0.5">v_unified_opportunities</p>
                    </div>
                    {renderStatusBadge("refresh_opportunities", globalLogs)}
                  </div>
                  {renderButton("refresh_opportunities", "Atualizar", false, null, globalLogs)}
                </div>
              </div>
            </div>
          </div>
        </TabsContent>

        {/* Tab 2: Logs Table */}
        <TabsContent value="logs" className="mt-6">
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-lg">Logs de Processamento</CardTitle>
              <CardDescription>Histórico de execuções de importação, atualizações e rollbacks no sistema.</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="rounded-lg border border-slate-200 overflow-hidden">
                <Table>
                  <TableHeader>
                    <TableRow className="bg-slate-50">
                      <TableHead>Programa / Ciclo</TableHead>
                      <TableHead>Tipo de Importação</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Executado Por</TableHead>
                      <TableHead className="text-right">Registros</TableHead>
                      <TableHead>Data / Hora</TableHead>
                      <TableHead>Duração</TableHead>
                      <TableHead>Detalhes / Erros</TableHead>
                      <TableHead className="text-right">Ações</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {isLoadingLogs ? (
                      Array.from({ length: 5 }).map((_, i) => (
                        <TableRow key={i}>
                          <TableCell><Skeleton className="h-4 w-32" /></TableCell>
                          <TableCell><Skeleton className="h-4 w-24" /></TableCell>
                          <TableCell><Skeleton className="h-4 w-20" /></TableCell>
                          <TableCell><Skeleton className="h-4 w-24" /></TableCell>
                          <TableCell><Skeleton className="h-4 w-16 ml-auto" /></TableCell>
                          <TableCell><Skeleton className="h-4 w-28" /></TableCell>
                          <TableCell><Skeleton className="h-4 w-16" /></TableCell>
                          <TableCell><Skeleton className="h-4 w-40" /></TableCell>
                          <TableCell><Skeleton className="h-8 w-8 ml-auto" /></TableCell>
                        </TableRow>
                      ))
                    ) : logs.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={9} className="text-center py-8 text-muted-foreground text-sm">
                          Nenhum log de processamento encontrado.
                        </TableCell>
                      </TableRow>
                    ) : (
                      logs.map((log) => {
                        let durationStr = "-";
                        if (log.started_at && log.finished_at) {
                          const start = new Date(log.started_at).getTime();
                          const end = new Date(log.finished_at).getTime();
                          const diffSec = Math.round((end - start) / 1000);
                          if (diffSec < 60) {
                            durationStr = `${diffSec}s`;
                          } else {
                            const mins = Math.floor(diffSec / 60);
                            const secs = diffSec % 60;
                            durationStr = `${mins}m ${secs}s`;
                          }
                        } else if (log.status === "running") {
                          durationStr = "Em andamento...";
                        }

                        return (
                          <TableRow key={log.id}>
                            <TableCell>
                              {log.programs?.title ? (
                                <div className="flex flex-col gap-0.5">
                                  <span className="font-semibold text-slate-900 text-xs">{log.programs.title}</span>
                                  <div className="flex items-center gap-1.5">
                                    <span className="text-[11px] text-muted-foreground">
                                      Ciclo: {log.programs.cycle_year}.{log.programs.cycle_semester}
                                    </span>
                                    {log.programs.status === "opened" && (
                                      <span className="inline-flex items-center px-1.5 py-0.2 rounded text-[10px] font-medium bg-emerald-50 text-emerald-700 border border-emerald-200">
                                        Aberto
                                      </span>
                                    )}
                                    {log.programs.status === "closed" && (
                                      <span className="inline-flex items-center px-1.5 py-0.2 rounded text-[10px] font-medium bg-slate-100 text-slate-700 border border-slate-200">
                                        Encerrado
                                      </span>
                                    )}
                                    {log.programs.status === "incoming" && (
                                      <span className="inline-flex items-center px-1.5 py-0.2 rounded text-[10px] font-medium bg-sky-50 text-sky-700 border border-sky-200">
                                        Em breve
                                      </span>
                                    )}
                                  </div>
                                </div>
                              ) : (
                                <span className="text-muted-foreground italic text-xs">Global / Sem ciclo</span>
                              )}
                            </TableCell>
                            <TableCell>
                              <span className="font-mono text-[11px] font-medium bg-slate-50 px-2 py-0.5 rounded inline-block border border-slate-200">
                                {typeLabels[log.etl_type] || log.etl_type}
                              </span>
                            </TableCell>
                            <TableCell>
                              {log.status === "success" && (
                                <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-semibold bg-emerald-50 text-emerald-700 border border-emerald-200">
                                  <CheckCircle className="w-3.5 h-3.5" /> Sucesso
                                </span>
                              )}
                              {log.status === "error" && (
                                <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-semibold bg-red-50 text-red-700 border border-red-200">
                                  <AlertCircle className="w-3.5 h-3.5" /> Erro
                                </span>
                              )}
                              {log.status === "running" && (
                                <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-semibold bg-sky-50 text-sky-700 border border-sky-200 animate-pulse">
                                  <Loader className="w-3.5 h-3.5 animate-spin" /> Rodando
                                </span>
                              )}
                              {log.status === "cancelled" && (
                                <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-semibold bg-amber-50 text-amber-700 border border-amber-200">
                                  <Square className="w-3.5 h-3.5 fill-current" /> Cancelado
                                </span>
                              )}
                            </TableCell>
                            <TableCell className="text-xs text-slate-700 font-medium">
                              {log.user_name || <span className="text-muted-foreground italic">Sistema</span>}
                            </TableCell>
                            <TableCell className="text-right font-mono text-xs font-semibold">
                              {log.records_processed !== null ? Number(log.records_processed).toLocaleString("pt-BR") : "-"}
                            </TableCell>
                            <TableCell className="text-muted-foreground text-xs">
                              {new Date(log.started_at).toLocaleString("pt-BR")}
                            </TableCell>
                            <TableCell className="text-xs font-medium text-slate-700">{durationStr}</TableCell>
                            <TableCell className="max-w-[280px]">
                              {log.errors ? (
                                <div
                                  className={`text-[11px] p-2 rounded border font-mono max-h-[100px] overflow-y-auto whitespace-pre-wrap ${
                                    log.etl_type.startsWith("rollback_") && log.status === "success"
                                      ? "text-sky-700 bg-sky-50/60 border-sky-200"
                                      : log.status === "success"
                                      ? "text-emerald-700 bg-emerald-50/60 border-emerald-200"
                                      : "text-red-600 bg-red-50/50 border-red-100"
                                  }`}
                                >
                                  {log.errors}
                                </div>
                              ) : (
                                <span className="text-xs text-muted-foreground italic">-</span>
                              )}
                            </TableCell>
                            <TableCell className="text-right">
                              {!log.etl_type.startsWith("rollback_") && (
                                <>
                                  {log.status === "running" ? (
                                    <Button
                                      variant="destructive"
                                      size="sm"
                                      onClick={() => stopStep({ logId: log.id })}
                                      disabled={isStopping && stopVars?.logId === log.id}
                                      title="Parar execução"
                                    >
                                      {isStopping && stopVars?.logId === log.id ? (
                                        <Loader className="h-3.5 w-3.5 animate-spin" />
                                      ) : (
                                        <Square className="h-3.5 w-3.5 fill-current" />
                                      )}
                                    </Button>
                                  ) : (
                                    <AlertDialog>
                                      <AlertDialogTrigger asChild>
                                        <Button
                                          variant="outline"
                                          size="sm"
                                          disabled={
                                            log.etl_type === "emec" ||
                                            log.etl_type.startsWith("refresh_") ||
                                            (isRollingBack && rollbackVars?.logId === log.id)
                                          }
                                          title="Limpar dados do ciclo associado a esta importação"
                                        >
                                          {isRollingBack && rollbackVars?.logId === log.id ? (
                                            <span className="flex items-center gap-1">
                                              <Loader className="h-3.5 w-3.5 animate-spin" />
                                              {rollbackProgress?.logId === log.id && rollbackProgress.processed > 0
                                                ? rollbackProgress.processed.toLocaleString("pt-BR")
                                                : "..."}
                                            </span>
                                          ) : (
                                            <Undo2 className="h-3.5 w-3.5" />
                                          )}
                                        </Button>
                                      </AlertDialogTrigger>
                                      <AlertDialogContent>
                                        <AlertDialogHeader>
                                          <AlertDialogTitle>Confirmar Rollback</AlertDialogTitle>
                                          <AlertDialogDescription>
                                            Tem certeza que deseja desfazer esta operação? Esta ação deletará todos os registros de vagas e oportunidades associados a este log no banco de dados.
                                          </AlertDialogDescription>
                                        </AlertDialogHeader>
                                        <AlertDialogFooter>
                                          <AlertDialogCancel>Cancelar</AlertDialogCancel>
                                          <AlertDialogAction
                                            onClick={() => rollbackStep({ logId: log.id })}
                                            className="bg-red-600 hover:bg-red-700 focus:ring-red-600"
                                          >
                                            Confirmar Rollback
                                          </AlertDialogAction>
                                        </AlertDialogFooter>
                                      </AlertDialogContent>
                                    </AlertDialog>
                                  )}
                                </>
                              )}
                            </TableCell>
                          </TableRow>
                        );
                      })
                    )}
                  </TableBody>
                </Table>
              </div>

              {/* Pagination */}
              <div className="flex items-center justify-between mt-4">
                <div className="text-xs text-slate-500">
                  {logsCount !== undefined && <span>Total de {logsCount} logs de processamento</span>}
                </div>
                <div className="flex items-center gap-2">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setLogsPage((p) => Math.max(0, p - 1))}
                    disabled={logsPage === 0 || isLoadingLogs}
                  >
                    <ChevronLeft className="h-3.5 w-3.5 mr-1" /> Anterior
                  </Button>
                  <div className="text-xs px-2 font-medium text-slate-700">Página {logsPage + 1}</div>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setLogsPage((p) => p + 1)}
                    disabled={!logs || logs.length < logsPageSize || isLoadingLogs}
                  >
                    Próxima <ChevronRight className="h-3.5 w-3.5 ml-1" />
                  </Button>
                </div>
              </div>
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  );
}
