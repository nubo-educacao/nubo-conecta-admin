import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { getInstitutions } from "@/services/educationalDataService";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ChevronLeft, ChevronRight, Search } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import ImportPipelineControl from "@/components/institutions/ImportPipelineControl";
import { useAllEtlLogs, useRollbackEtlStep, useStopEtlStep } from "@/hooks/useEtlPipeline";
import { AlertCircle, CheckCircle, Clock, Loader, Undo2, Square } from "lucide-react";
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

export default function Institutions() {
    const [page, setPage] = useState(0);
    const [search, setSearch] = useState("");
    const [searchInput, setSearchInput] = useState("");
    const pageSize = 20;

    const { data, isLoading, isError } = useQuery({
        queryKey: ["institutions", page, pageSize, search],
        queryFn: () => getInstitutions(page, pageSize, search),
    });

    const [logsPage, setLogsPage] = useState(0);
    const logsPageSize = 20;
    const { data: logsData, isLoading: isLoadingLogs } = useAllEtlLogs(logsPage, logsPageSize);
    const logs = logsData?.data || [];
    const logsCount = logsData?.count || 0;
    
    const { mutate: rollbackStep, isPending: isRollingBack, variables: rollbackVars, rollbackProgress } = useRollbackEtlStep();
    const { mutate: stopStep, isPending: isStopping, variables: stopVars } = useStopEtlStep();

    const handleSearch = () => {
        setPage(0);
        setSearch(searchInput);
    };

    return (
        <div className="p-6 space-y-6">
            <div>
                <h1 className="text-3xl font-bold tracking-tight">Instituições</h1>
                <p className="text-muted-foreground">Visualize as instituições do Ministério da Educação e orquestre o pipeline de dados.</p>
            </div>

            <Tabs defaultValue="list" className="w-full">
                <TabsList className="mb-4">
                    <TabsTrigger value="list">Catálogo</TabsTrigger>
                    <TabsTrigger value="import">Importações (ETL)</TabsTrigger>
                    <TabsTrigger value="logs">Logs de Processamento</TabsTrigger>
                </TabsList>

                <TabsContent value="list" className="space-y-6">
                    <div className="flex items-center gap-2 max-w-sm">
                        <Input 
                            placeholder="Buscar por nome..." 
                            value={searchInput}
                            onChange={(e) => setSearchInput(e.target.value)}
                            onKeyDown={(e) => e.key === 'Enter' && handleSearch()}
                        />
                        <Button variant="outline" size="icon" onClick={handleSearch}>
                            <Search className="h-4 w-4" />
                        </Button>
                    </div>

                    <div className="rounded-md border bg-white relative min-h-[400px]">
                        <Table>
                            <TableHeader>
                                <TableRow>
                                    <TableHead>Nome</TableHead>
                                    <TableHead>Código Externo (MEC)</TableHead>
                                    <TableHead>Criado em</TableHead>
                                </TableRow>
                            </TableHeader>
                            <TableBody>
                                {isLoading ? (
                                    Array.from({ length: 5 }).map((_, i) => (
                                        <TableRow key={i}>
                                            <TableCell><Skeleton className="h-4 w-[250px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[100px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[100px]" /></TableCell>
                                        </TableRow>
                                    ))
                                ) : isError ? (
                                    <TableRow>
                                        <TableCell colSpan={3} className="h-24 text-center text-red-500">
                                            Erro ao carregar instituições.
                                        </TableCell>
                                    </TableRow>
                                ) : data?.data?.length === 0 ? (
                                    <TableRow>
                                        <TableCell colSpan={3} className="h-24 text-center">
                                            Nenhuma instituição encontrada.
                                        </TableCell>
                                    </TableRow>
                                ) : (
                                    data?.data?.map((inst: any) => (
                                        <TableRow key={inst.id}>
                                            <TableCell className="font-medium">{inst.name}</TableCell>
                                            <TableCell>{inst.external_code || "-"}</TableCell>
                                            <TableCell>{new Date(inst.created_at).toLocaleDateString("pt-BR")}</TableCell>
                                        </TableRow>
                                    ))
                                )}
                            </TableBody>
                        </Table>
                    </div>

                    <div className="flex items-center justify-between">
                        <div className="text-sm text-muted-foreground">
                            {data?.count !== undefined && (
                                <span>Total de {data.count} registros</span>
                            )}
                        </div>
                        <div className="flex items-center gap-2">
                            <Button 
                                variant="outline" 
                                size="sm" 
                                onClick={() => setPage(p => Math.max(0, p - 1))}
                                disabled={page === 0 || isLoading}
                            >
                                <ChevronLeft className="h-4 w-4 mr-1" /> Anterior
                            </Button>
                            <div className="text-sm px-2">Página {page + 1}</div>
                            <Button 
                                variant="outline" 
                                size="sm" 
                                onClick={() => setPage(p => p + 1)}
                                disabled={!data?.data || data.data.length < pageSize || isLoading}
                            >
                                Próxima <ChevronRight className="h-4 w-4 ml-1" />
                            </Button>
                        </div>
                    </div>
                </TabsContent>

                <TabsContent value="import">
                    <ImportPipelineControl />
                </TabsContent>

                <TabsContent value="logs" className="space-y-6">
                    <div className="rounded-md border bg-white relative min-h-[400px]">
                        <Table>
                            <TableHeader>
                                <TableRow>
                                    <TableHead>Ciclo / Programa</TableHead>
                                    <TableHead>Processamento (Tipo)</TableHead>
                                    <TableHead>Status</TableHead>
                                    <TableHead>Executado por</TableHead>
                                    <TableHead className="text-right">Registros Processados</TableHead>
                                    <TableHead>Iniciado em</TableHead>
                                    <TableHead>Duração</TableHead>
                                    <TableHead>Detalhes / Erro</TableHead>
                                    <TableHead className="text-right">Ações</TableHead>
                                </TableRow>
                            </TableHeader>
                            <TableBody>
                                {isLoadingLogs ? (
                                    Array.from({ length: 5 }).map((_, i) => (
                                        <TableRow key={i}>
                                            <TableCell><Skeleton className="h-4 w-[150px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[120px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[80px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[100px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[100px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[150px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[60px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[200px]" /></TableCell>
                                            <TableCell><Skeleton className="h-4 w-[60px]" /></TableCell>
                                        </TableRow>
                                    ))
                                ) : !logs || logs.length === 0 ? (
                                    <TableRow>
                                        <TableCell colSpan={8} className="h-24 text-center">
                                            Nenhum log de processamento encontrado.
                                        </TableCell>
                                    </TableRow>
                                ) : (
                                    logs.map((log: any) => {
                                        const typeLabels: Record<string, string> = {
                                            sisu: "Base SiSU",
                                            sisu_vacancies: "Vagas SiSU",
                                            prouni_base: "Base ProUni",
                                            prouni_vacancies: "Vagas ProUni",
                                            prouni_occupied: "Ocupação ProUni",
                                            emec: "e-MEC",
                                            refresh_opportunities: "Sincronização Opportunities",
                                            rollback_sisu: "Base SiSU (Rollback)",
                                            rollback_sisu_vacancies: "Vagas SiSU (Rollback)",
                                            rollback_prouni_base: "Base ProUni (Rollback)",
                                            rollback_prouni_vacancies: "Vagas ProUni (Rollback)",
                                            rollback_prouni_occupied: "Ocupação ProUni (Rollback)",
                                        };

                                        // Duration calculation
                                        let durationStr = "-";
                                        if (log.started_at && log.finished_at) {
                                            const start = new Date(log.started_at).getTime();
                                            const end = new Date(log.finished_at).getTime();
                                            const diffMs = end - start;
                                            const diffSec = Math.round(diffMs / 1000);
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
                                                        <div className="flex flex-col gap-1">
                                                            <span className="font-semibold text-slate-900">{log.programs.title}</span>
                                                            <div className="flex items-center gap-2">
                                                                <span className="text-[11px] text-muted-foreground">
                                                                    Ciclo: {log.programs.cycle_year}.{log.programs.cycle_semester}
                                                                </span>
                                                                {log.programs.status === 'opened' && (
                                                                    <span className="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-emerald-50 text-emerald-700 border border-emerald-200">
                                                                        Aberto
                                                                    </span>
                                                                )}
                                                                {log.programs.status === 'closed' && (
                                                                    <span className="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-slate-100 text-slate-700 border border-slate-200">
                                                                        Encerrado
                                                                    </span>
                                                                )}
                                                                {log.programs.status === 'incoming' && (
                                                                    <span className="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-blue-50 text-blue-700 border border-blue-200">
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
                                                    <span className="font-mono text-xs font-medium bg-slate-50 px-2 py-1 rounded inline-block border border-slate-100">
                                                        {typeLabels[log.etl_type] || log.etl_type}
                                                    </span>
                                                </TableCell>
                                                <TableCell>
                                                    {log.status === "success" && (
                                                        <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-emerald-50 text-emerald-700 border border-emerald-200">
                                                            <CheckCircle className="w-3.5 h-3.5" /> Sucesso
                                                        </span>
                                                    )}
                                                    {log.status === "error" && (
                                                        <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-red-50 text-red-700 border border-red-200">
                                                            <AlertCircle className="w-3.5 h-3.5" /> Erro
                                                        </span>
                                                    )}
                                                    {log.status === "running" && (
                                                        <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-blue-50 text-blue-700 border border-blue-200 animate-pulse">
                                                            <Loader className="w-3.5 h-3.5 animate-spin" /> Rodando
                                                        </span>
                                                    )}
                                                    {log.status === "cancelled" && (
                                                        <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-amber-50 text-amber-700 border border-amber-200">
                                                            <Square className="w-3.5 h-3.5 fill-current" /> Cancelado
                                                        </span>
                                                    )}
                                                </TableCell>
                                                <TableCell className="text-sm text-slate-700 font-medium">
                                                    {log.user_name || (
                                                        <span className="text-muted-foreground italic text-xs">Sistema / Automatizado</span>
                                                    )}
                                                </TableCell>
                                                <TableCell className="text-right font-mono font-semibold">
                                                    {log.records_processed !== null ? Number(log.records_processed).toLocaleString("pt-BR") : "-"}
                                                </TableCell>
                                                <TableCell className="text-muted-foreground text-xs">
                                                    {new Date(log.started_at).toLocaleString("pt-BR")}
                                                </TableCell>
                                                <TableCell className="text-sm font-medium text-slate-700">
                                                    {durationStr}
                                                </TableCell>
                                                <TableCell className="max-w-[300px]">
                                                    {log.errors ? (
                                                        <div className={`text-xs p-2 rounded border font-mono max-h-[130px] overflow-y-auto whitespace-pre-wrap ${
                                                            log.etl_type.startsWith('rollback_') && log.status === 'success'
                                                                ? 'text-blue-700 bg-blue-50/60 border-blue-200'
                                                                : log.status === 'success'
                                                                    ? 'text-emerald-700 bg-emerald-50/60 border-emerald-200'
                                                                    : 'text-red-600 bg-red-50/50 border-red-100'
                                                        }`}>
                                                            {log.errors}
                                                        </div>
                                                    ) : (
                                                        <span className="text-xs text-muted-foreground italic">-</span>
                                                    )}
                                                </TableCell>
                                                <TableCell className="text-right">
                                                    {!log.etl_type.startsWith('rollback_') && (
                                                        <>
                                                            {log.status === 'running' ? (
                                                                <Button
                                                                    variant="destructive"
                                                                    size="sm"
                                                                    onClick={() => stopStep({ logId: log.id })}
                                                                    disabled={isStopping && stopVars?.logId === log.id}
                                                                    title="Parar execução"
                                                                >
                                                                    {isStopping && stopVars?.logId === log.id ? (
                                                                        <Loader className="h-4 w-4 animate-spin" />
                                                                    ) : (
                                                                        <Square className="h-4 w-4 fill-current" />
                                                                    )}
                                                                </Button>
                                                            ) : (
                                                                <AlertDialog>
                                                                    <AlertDialogTrigger asChild>
                                                                        <Button
                                                                            variant="outline"
                                                                            size="sm"
                                                                            disabled={log.status === 'running' || log.etl_type === 'emec' || log.etl_type.startsWith('refresh_') || (isRollingBack && rollbackVars?.logId === log.id)}
                                                                            title="Limpar dados do ciclo associado a esta importação"
                                                                        >
                                                                            {isRollingBack && rollbackVars?.logId === log.id ? (
                                                                                <span className="flex items-center gap-1">
                                                                                    <Loader className="h-3.5 w-3.5 animate-spin" />
                                                                                    {rollbackProgress?.logId === log.id && rollbackProgress.processed > 0
                                                                                    ? rollbackProgress.processed.toLocaleString('pt-BR')
                                                                                    : '...'}
                                                                                </span>
                                                                            ) : <Undo2 className="h-4 w-4" />}
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
                                                                            <AlertDialogAction onClick={() => rollbackStep({ logId: log.id })} className="bg-red-600 hover:bg-red-700 focus:ring-red-600">
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
                    <div className="flex items-center justify-between mt-4">
                        <div className="text-sm text-muted-foreground">
                            {logsCount !== undefined && (
                                <span>Total de {logsCount} logs de processamento</span>
                            )}
                        </div>
                        <div className="flex items-center gap-2">
                            <Button 
                                variant="outline" 
                                size="sm" 
                                onClick={() => setLogsPage(p => Math.max(0, p - 1))}
                                disabled={logsPage === 0 || isLoadingLogs}
                            >
                                <ChevronLeft className="h-4 w-4 mr-1" /> Anterior
                            </Button>
                            <div className="text-sm px-2">Página {logsPage + 1}</div>
                            <Button 
                                variant="outline" 
                                size="sm" 
                                onClick={() => setLogsPage(p => p + 1)}
                                disabled={!logs || logs.length < logsPageSize || isLoadingLogs}
                            >
                                Próxima <ChevronRight className="h-4 w-4 ml-1" />
                            </Button>
                        </div>
                    </div>
                </TabsContent>
            </Tabs>
        </div>
    );
}
