// Histórico de execuções do pipeline (etl_run_logs).
// Extraído do DataPipeline para que a tela de Importação não precise de abas
// aninhadas: ProgramsImport expõe "Importação (ETL)" e "Logs de Processamento"
// lado a lado, no mesmo nível de "Programas".
import { useState } from "react";
import { useAllEtlLogs, useRollbackEtlStep, useStopEtlStep } from "@/hooks/useEtlPipeline";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
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
import { AlertCircle, CheckCircle, ChevronLeft, ChevronRight, Loader, Square, Undo2 } from "lucide-react";

export const ETL_TYPE_LABELS: Record<string, string> = {
  sisu: "Base SiSU",
  sisu_vacancies: "Vagas SiSU",
  prouni_base: "Base ProUni",
  prouni_clone: "Herança ProUni (Clonagem)",
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

const PROGRAM_STATUS_LABELS: Record<string, string> = {
  opened: "Aberto",
  closed: "Encerrado",
  incoming: "Em breve",
};

export function formatDuration(startedAt: string | null, finishedAt: string | null, status: string) {
  if (startedAt && finishedAt) {
    const diffSec = Math.round((new Date(finishedAt).getTime() - new Date(startedAt).getTime()) / 1000);
    if (diffSec < 60) return `${diffSec}s`;
    return `${Math.floor(diffSec / 60)}m ${diffSec % 60}s`;
  }
  return status === "running" ? "Em andamento..." : "-";
}

function LogStatusBadge({ status }: { status: string }) {
  if (status === "success") {
    return (
      <Badge className="gap-1 border-emerald-200 bg-emerald-50 text-emerald-700 hover:bg-emerald-50">
        <CheckCircle className="h-3.5 w-3.5" /> Sucesso
      </Badge>
    );
  }
  if (status === "error") {
    return (
      <Badge className="gap-1 border-red-200 bg-red-50 text-red-700 hover:bg-red-50">
        <AlertCircle className="h-3.5 w-3.5" /> Erro
      </Badge>
    );
  }
  if (status === "running") {
    return (
      <Badge className="animate-pulse gap-1 border-sky-200 bg-sky-50 text-sky-700 hover:bg-sky-50">
        <Loader className="h-3.5 w-3.5 animate-spin" /> Rodando
      </Badge>
    );
  }
  if (status === "cancelled") {
    return (
      <Badge className="gap-1 border-amber-200 bg-amber-50 text-amber-700 hover:bg-amber-50">
        <Square className="h-3.5 w-3.5 fill-current" /> Cancelado
      </Badge>
    );
  }
  return <Badge variant="outline">{status}</Badge>;
}

const PAGE_SIZE = 20;

export default function EtlProcessingLogs() {
  const [page, setPage] = useState(0);
  const { data, isLoading } = useAllEtlLogs(page, PAGE_SIZE);
  const logs = data?.data || [];
  const count = data?.count || 0;

  const {
    mutate: rollbackStep,
    isPending: isRollingBack,
    variables: rollbackVars,
    rollbackProgress,
  } = useRollbackEtlStep();
  const { mutate: stopStep, isPending: isStopping, variables: stopVars } = useStopEtlStep();

  return (
    <Card>
      <CardHeader>
        <CardTitle>Logs de Processamento</CardTitle>
        <CardDescription>
          Histórico de execuções de importação, clonagens, sincronizações e rollbacks no sistema.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="overflow-x-auto rounded-md border">
          <Table>
            <TableHeader>
              <TableRow className="bg-muted/40">
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
              {isLoading ? (
                Array.from({ length: 5 }).map((_, i) => (
                  <TableRow key={i}>
                    {Array.from({ length: 9 }).map((__, j) => (
                      <TableCell key={j}>
                        <Skeleton className="h-4 w-24" />
                      </TableCell>
                    ))}
                  </TableRow>
                ))
              ) : logs.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={9} className="h-24 text-center text-sm text-muted-foreground">
                    Nenhum log de processamento encontrado.
                  </TableCell>
                </TableRow>
              ) : (
                logs.map((log) => {
                  const isRollbackEntry = log.etl_type.startsWith("rollback_");
                  return (
                    <TableRow key={log.id}>
                      <TableCell>
                        {log.programs?.title ? (
                          <div className="flex flex-col gap-1">
                            <span className="text-xs font-semibold">{log.programs.title}</span>
                            <div className="flex items-center gap-1.5">
                              <span className="text-[11px] text-muted-foreground">
                                Ciclo: {log.programs.cycle_year}.{log.programs.cycle_semester}
                              </span>
                              {PROGRAM_STATUS_LABELS[log.programs.status] && (
                                <Badge variant="outline" className="px-1.5 py-0 text-[10px] font-medium">
                                  {PROGRAM_STATUS_LABELS[log.programs.status]}
                                </Badge>
                              )}
                            </div>
                          </div>
                        ) : (
                          <span className="text-xs italic text-muted-foreground">Global / Sem ciclo</span>
                        )}
                      </TableCell>
                      <TableCell>
                        <span className="inline-block rounded border bg-muted/40 px-2 py-0.5 font-mono text-[11px] font-medium">
                          {ETL_TYPE_LABELS[log.etl_type] || log.etl_type}
                        </span>
                      </TableCell>
                      <TableCell>
                        <LogStatusBadge status={log.status} />
                      </TableCell>
                      <TableCell className="text-xs font-medium">
                        {log.user_name || <span className="italic text-muted-foreground">Sistema</span>}
                      </TableCell>
                      <TableCell className="text-right font-mono text-xs font-semibold">
                        {log.records_processed !== null
                          ? Number(log.records_processed).toLocaleString("pt-BR")
                          : "-"}
                      </TableCell>
                      <TableCell className="text-xs text-muted-foreground">
                        {new Date(log.started_at).toLocaleString("pt-BR")}
                      </TableCell>
                      <TableCell className="text-xs font-medium">
                        {formatDuration(log.started_at, log.finished_at, log.status)}
                      </TableCell>
                      <TableCell className="min-w-[220px] max-w-[320px]">
                        {log.errors ? (
                          <ScrollArea className="max-h-[110px]">
                            <div
                              className={`whitespace-pre-wrap rounded border p-2 font-mono text-[11px] ${
                                isRollbackEntry && log.status === "success"
                                  ? "border-sky-200 bg-sky-50/60 text-sky-700"
                                  : log.status === "success"
                                    ? "border-emerald-200 bg-emerald-50/60 text-emerald-700"
                                    : "border-red-100 bg-red-50/50 text-red-600"
                              }`}
                            >
                              {log.errors}
                            </div>
                          </ScrollArea>
                        ) : (
                          <span className="text-xs italic text-muted-foreground">-</span>
                        )}
                      </TableCell>
                      <TableCell className="text-right">
                        {!isRollbackEntry &&
                          (log.status === "running" ? (
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
                                    Tem certeza que deseja desfazer esta operação? Esta ação deletará todos os
                                    registros de vagas e oportunidades associados a este log no banco de dados.
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
                          ))}
                      </TableCell>
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </div>

        <div className="flex items-center justify-between">
          <span className="text-xs text-muted-foreground">Total de {count} logs de processamento</span>
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setPage((p) => Math.max(0, p - 1))}
              disabled={page === 0 || isLoading}
            >
              <ChevronLeft className="mr-1 h-3.5 w-3.5" /> Anterior
            </Button>
            <span className="px-2 text-xs font-medium">Página {page + 1}</span>
            <Button
              variant="outline"
              size="sm"
              onClick={() => setPage((p) => p + 1)}
              disabled={logs.length < PAGE_SIZE || isLoading}
            >
              Próxima <ChevronRight className="ml-1 h-3.5 w-3.5" />
            </Button>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
