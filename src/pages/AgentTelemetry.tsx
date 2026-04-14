import { useState } from "react";
import {
  Activity,
  AlertCircle,
  AlertTriangle,
  CheckCircle,
  Clock,
  Filter,
  Info,
  RefreshCw,
  Wrench,
  XCircle,
  Zap,
} from "lucide-react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { cn } from "@/lib/utils";
import {
  useTelemetryKPIs,
  useLatencyByHour,
  useTokensByDay,
  useTurnsList,
  useToolStats,
} from "@/hooks/useAgentTelemetry";
import { useErrorLogs } from "@/hooks/useAnalyticsData";
import TurnDrillDown from "@/components/telemetry/TurnDrillDown";
import type { AgentTurnRow } from "@/lib/telemetry-queries";

import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
  BarChart,
  Bar,
} from "recharts";

// ─── Cores da paleta para gráficos ──────────────────────────────────────────
const COLORS = {
  planning: "#8b5cf6",
  reasoning: "#f59e0b",
  response: "#10b981",
  input: "#38bdf8",
  output: "#0369a1",
};

// ─── Configuração de tipos de erro ──────────────────────────────────────────
const typeConfig = {
  error: {
    icon: AlertCircle,
    bgClass: "bg-destructive/10",
    textClass: "text-destructive",
    badgeVariant: "destructive" as const,
    label: "Erro",
  },
  warning: {
    icon: AlertTriangle,
    bgClass: "bg-warning/10",
    textClass: "text-warning",
    badgeVariant: "secondary" as const,
    label: "Aviso",
  },
  info: {
    icon: Info,
    bgClass: "bg-primary/10",
    textClass: "text-primary",
    badgeVariant: "outline" as const,
    label: "Info",
  },
};

export default function AgentTelemetry() {
  const kpis = useTelemetryKPIs();
  const latencyData = useLatencyByHour();
  const tokensData = useTokensByDay();
  const turnsList = useTurnsList();
  const toolStats = useToolStats();
  const errorLogs = useErrorLogs();

  const [selectedTurn, setSelectedTurn] = useState<AgentTurnRow | null>(null);
  const [drillDownOpen, setDrillDownOpen] = useState(false);
  const [filterType, setFilterType] = useState<string>("all");
  const [filterStatus, setFilterStatus] = useState<string>("all");

  const handleTurnClick = (turn: AgentTurnRow) => {
    setSelectedTurn(turn);
    setDrillDownOpen(true);
  };

  const handleRefresh = () => {
    kpis.refetch();
    latencyData.refetch();
    tokensData.refetch();
    turnsList.refetch();
    toolStats.refetch();
    errorLogs.refetch();
  };

  const isRefetching = kpis.isRefetching || latencyData.isRefetching;

  const filteredErrors = errorLogs.data?.filter((err) => {
    if (filterType !== "all" && err.type !== filterType) return false;
    if (filterStatus === "resolved" && !err.resolved) return false;
    if (filterStatus === "unresolved" && err.resolved) return false;
    return true;
  });

  return (
    <div className="flex-1 space-y-6 p-8 pt-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-3xl font-bold tracking-tight">Telemetria Multi-Agente</h2>
          <p className="text-muted-foreground">
            Observabilidade da pipeline Planning → Reasoning → Response
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={handleRefresh} disabled={isRefetching}>
          <RefreshCw className={`h-4 w-4 mr-2 ${isRefetching ? "animate-spin" : ""}`} />
          Atualizar
        </Button>
      </div>

      {/* KPI Cards */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {kpis.isLoading ? (
          [...Array(4)].map((_, i) => <Skeleton key={i} className="h-24" />)
        ) : (
          <>
            <KPICard
              icon={Clock}
              label="Latência Média"
              value={`${((kpis.data?.avgLatencyMs ?? 0) / 1000).toFixed(1)}s`}
            />
            <KPICard
              icon={Activity}
              label="Turnos (24h)"
              value={(kpis.data?.turnsLast24h ?? 0).toLocaleString()}
            />
            <KPICard
              icon={Zap}
              label="Tokens Usados"
              value={formatTokens(kpis.data?.totalTokens ?? 0)}
            />
            <KPICard
              icon={Wrench}
              label="Tools Chamadas"
              value={(kpis.data?.totalToolCalls ?? 0).toLocaleString()}
            />
          </>
        )}
      </div>

      {/* Tabs */}
      <Tabs defaultValue="metrics" className="space-y-4">
        <TabsList className="bg-muted/50 border">
          <TabsTrigger value="metrics">📊 Métricas de Turnos</TabsTrigger>
          <TabsTrigger value="errors">
            🚨 Erros
            {errorLogs.data && errorLogs.data.length > 0 && (
              <Badge variant="destructive" className="ml-2 h-5 min-w-5 text-[10px]">
                {errorLogs.data.length}
              </Badge>
            )}
          </TabsTrigger>
        </TabsList>

        {/* ── Aba 1: Métricas ─────────────────────────────────────── */}
        <TabsContent value="metrics" className="space-y-6">
          {/* Gráficos lado-a-lado */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            {/* Latência por Fase */}
            <div className="rounded-lg border bg-card p-4">
              <h3 className="text-sm font-semibold mb-4">Latência por Fase (ms)</h3>
              {latencyData.isLoading ? (
                <Skeleton className="h-64" />
              ) : (
                <ResponsiveContainer width="100%" height={260}>
                  <AreaChart data={latencyData.data ?? []}>
                    <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
                    <XAxis dataKey="hour" tick={{ fontSize: 11 }} />
                    <YAxis tick={{ fontSize: 11 }} />
                    <Tooltip />
                    <Legend />
                    <Area
                      type="monotone"
                      dataKey="planning"
                      name="planning"
                      stroke={COLORS.planning}
                      fill={COLORS.planning}
                      fillOpacity={0.3}
                      stackId="1"
                    />
                    <Area
                      type="monotone"
                      dataKey="reasoning"
                      name="reasoning"
                      stroke={COLORS.reasoning}
                      fill={COLORS.reasoning}
                      fillOpacity={0.3}
                      stackId="1"
                    />
                    <Area
                      type="monotone"
                      dataKey="response"
                      name="response"
                      stroke={COLORS.response}
                      fill={COLORS.response}
                      fillOpacity={0.3}
                      stackId="1"
                    />
                  </AreaChart>
                </ResponsiveContainer>
              )}
            </div>

            {/* Consumo de Tokens */}
            <div className="rounded-lg border bg-card p-4">
              <h3 className="text-sm font-semibold mb-4">Consumo de Tokens</h3>
              {tokensData.isLoading ? (
                <Skeleton className="h-64" />
              ) : (
                <ResponsiveContainer width="100%" height={260}>
                  <BarChart data={tokensData.data ?? []}>
                    <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
                    <XAxis dataKey="day" tick={{ fontSize: 11 }} />
                    <YAxis tick={{ fontSize: 11 }} />
                    <Tooltip />
                    <Legend />
                    <Bar dataKey="input" name="input" fill={COLORS.input} radius={[4, 4, 0, 0]} />
                    <Bar
                      dataKey="output"
                      name="output"
                      fill={COLORS.output}
                      radius={[4, 4, 0, 0]}
                    />
                  </BarChart>
                </ResponsiveContainer>
              )}
            </div>
          </div>

          {/* Tabela de Sessões */}
          <div className="rounded-lg border bg-card">
            <div className="p-4 border-b">
              <h3 className="text-sm font-semibold">Sessões Recentes</h3>
              <p className="text-xs text-muted-foreground">
                Clique em uma linha para ver o drill-down completo
              </p>
            </div>
            {turnsList.isLoading ? (
              <div className="p-4 space-y-3">
                {[...Array(5)].map((_, i) => (
                  <Skeleton key={i} className="h-12" />
                ))}
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b bg-muted/30">
                      <th className="text-left p-3 font-medium text-muted-foreground">Sessão</th>
                      <th className="text-left p-3 font-medium text-muted-foreground">
                        Categoria
                      </th>
                      <th className="text-right p-3 font-medium text-muted-foreground">
                        Latência
                      </th>
                      <th className="text-right p-3 font-medium text-muted-foreground">Tokens</th>
                      <th className="text-right p-3 font-medium text-muted-foreground">Custo</th>
                      <th className="text-right p-3 font-medium text-muted-foreground">Data</th>
                    </tr>
                  </thead>
                  <tbody>
                    {(turnsList.data ?? []).map((turn) => (
                      <tr
                        key={turn.id}
                        className="border-b hover:bg-muted/20 cursor-pointer transition-colors"
                        onClick={() => handleTurnClick(turn)}
                      >
                        <td className="p-3 font-mono text-xs">
                          {turn.session_id?.slice(0, 12) ?? "—"}...
                        </td>
                        <td className="p-3">
                          <Badge variant="outline" className="text-xs">
                            {turn.intent_category ?? "—"}
                          </Badge>
                        </td>
                        <td className="p-3 text-right font-mono">
                          {turn.total_latency_ms ?? 0}ms
                        </td>
                        <td className="p-3 text-right font-mono">
                          {(
                            (turn.input_tokens ?? 0) + (turn.output_tokens ?? 0)
                          ).toLocaleString()}
                        </td>
                        <td className="p-3 text-right font-mono">
                          ${turn.estimated_cost_usd?.toFixed(4) ?? "—"}
                        </td>
                        <td className="p-3 text-right text-xs text-muted-foreground">
                          {new Date(turn.created_at).toLocaleString("pt-BR", {
                            day: "2-digit",
                            month: "2-digit",
                            hour: "2-digit",
                            minute: "2-digit",
                          })}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          {/* Tabela de Tools */}
          <div className="rounded-lg border bg-card">
            <div className="p-4 border-b">
              <h3 className="text-sm font-semibold">Tools Mais Chamadas</h3>
            </div>
            {toolStats.isLoading ? (
              <div className="p-4 space-y-3">
                {[...Array(3)].map((_, i) => (
                  <Skeleton key={i} className="h-10" />
                ))}
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b bg-muted/30">
                      <th className="text-left p-3 font-medium text-muted-foreground">Tool</th>
                      <th className="text-right p-3 font-medium text-muted-foreground">
                        Chamadas
                      </th>
                      <th className="text-right p-3 font-medium text-muted-foreground">
                        Latência Média
                      </th>
                      <th className="text-right p-3 font-medium text-muted-foreground">
                        Taxa de Sucesso
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {(toolStats.data ?? []).map((tool) => (
                      <tr key={tool.tool} className="border-b">
                        <td className="p-3 font-mono text-xs">{tool.tool}</td>
                        <td className="p-3 text-right">{tool.calls.toLocaleString()}</td>
                        <td className="p-3 text-right font-mono">{tool.avgLatencyMs}ms</td>
                        <td className="p-3 text-right">
                          <Badge
                            variant="outline"
                            className={
                              tool.successRate >= 99 ? "text-emerald-600" : "text-amber-600"
                            }
                          >
                            {tool.successRate.toFixed(1)}%
                          </Badge>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </TabsContent>

        {/* ── Aba 2: Erros ─────────────────────────────────────── */}
        <TabsContent value="errors" className="space-y-4">
          {/* Filters */}
          <div className="flex flex-wrap gap-4">
            <div className="flex items-center gap-2">
              <Filter className="h-4 w-4 text-muted-foreground" />
              <span className="text-sm font-medium">Filtros:</span>
            </div>

            <Select value={filterType} onValueChange={setFilterType}>
              <SelectTrigger className="w-[150px]">
                <SelectValue placeholder="Tipo" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">Todos os tipos</SelectItem>
                <SelectItem value="error">Erros</SelectItem>
                <SelectItem value="warning">Avisos</SelectItem>
                <SelectItem value="info">Info</SelectItem>
              </SelectContent>
            </Select>

            <Select value={filterStatus} onValueChange={setFilterStatus}>
              <SelectTrigger className="w-[150px]">
                <SelectValue placeholder="Status" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">Todos</SelectItem>
                <SelectItem value="resolved">Resolvidos</SelectItem>
                <SelectItem value="unresolved">Não resolvidos</SelectItem>
              </SelectContent>
            </Select>

            {(filterType !== "all" || filterStatus !== "all") && (
              <Button
                variant="ghost"
                size="sm"
                onClick={() => {
                  setFilterType("all");
                  setFilterStatus("all");
                }}
              >
                Limpar filtros
              </Button>
            )}
          </div>

          {/* Stats Summary */}
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <div className="rounded-lg border bg-card p-4">
              <div className="flex items-center gap-3">
                <div className="rounded-lg bg-destructive/10 p-2">
                  <AlertCircle className="h-5 w-5 text-destructive" />
                </div>
                <div>
                  <p className="text-2xl font-bold">
                    {errorLogs.data?.filter((e) => e.type === "error").length || 0}
                  </p>
                  <p className="text-sm text-muted-foreground">Erros críticos</p>
                </div>
              </div>
            </div>

            <div className="rounded-lg border bg-card p-4">
              <div className="flex items-center gap-3">
                <div className="rounded-lg bg-warning/10 p-2">
                  <AlertTriangle className="h-5 w-5 text-warning" />
                </div>
                <div>
                  <p className="text-2xl font-bold">
                    {errorLogs.data?.filter((e) => e.type === "warning").length || 0}
                  </p>
                  <p className="text-sm text-muted-foreground">Avisos</p>
                </div>
              </div>
            </div>

            <div className="rounded-lg border bg-card p-4">
              <div className="flex items-center gap-3">
                <div className="rounded-lg bg-success/10 p-2">
                  <CheckCircle className="h-5 w-5 text-success" />
                </div>
                <div>
                  <p className="text-2xl font-bold">
                    {errorLogs.data?.filter((e) => e.resolved).length || 0}
                  </p>
                  <p className="text-sm text-muted-foreground">Resolvidos</p>
                </div>
              </div>
            </div>
          </div>

          {/* Error List */}
          {errorLogs.isLoading ? (
            <div className="space-y-4">
              {[...Array(5)].map((_, i) => (
                <Skeleton key={i} className="h-24 w-full" />
              ))}
            </div>
          ) : errorLogs.error ? (
            <div className="flex flex-col items-center justify-center py-12 text-muted-foreground">
              <AlertCircle className="h-12 w-12 mb-4 opacity-50" />
              <p>Erro ao carregar logs</p>
            </div>
          ) : !filteredErrors || filteredErrors.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-12 text-muted-foreground">
              <CheckCircle className="h-12 w-12 mb-4 text-success opacity-70" />
              <p className="font-medium text-foreground">Nenhum erro encontrado!</p>
              <p className="text-sm mt-1">
                {filterType !== "all" || filterStatus !== "all"
                  ? "Tente ajustar os filtros"
                  : "Tudo funcionando normalmente"}
              </p>
            </div>
          ) : (
            <div className="space-y-4">
              {filteredErrors.map((errorItem, index) => {
                const config = typeConfig[errorItem.type];
                const Icon = config.icon;

                return (
                  <div
                    key={errorItem.id}
                    className={cn(
                      "rounded-lg border bg-card p-6 transition-all hover:shadow-md",
                      "opacity-0 animate-fade-in"
                    )}
                    style={{ animationDelay: `${index * 50}ms` }}
                  >
                    <div className="flex items-start gap-4">
                      <div className={cn("rounded-lg p-3", config.bgClass)}>
                        <Icon className={cn("h-5 w-5", config.textClass)} />
                      </div>

                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-3 flex-wrap mb-2">
                          <Badge variant={config.badgeVariant}>{config.label}</Badge>
                          <Badge variant={errorItem.resolved ? "outline" : "secondary"}>
                            {errorItem.resolved ? (
                              <>
                                <CheckCircle className="h-3 w-3 mr-1" /> Resolvido
                              </>
                            ) : (
                              <>
                                <XCircle className="h-3 w-3 mr-1" /> Pendente
                              </>
                            )}
                          </Badge>
                        </div>

                        <h3 className="font-semibold text-lg mb-2">{errorItem.message}</h3>

                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 mt-4">
                          <div>
                            <p className="text-xs text-muted-foreground uppercase tracking-wide mb-1">
                              Tipo de Erro
                            </p>
                            <p className="text-sm font-mono bg-muted px-2 py-1 rounded">
                              {errorItem.error_type}
                            </p>
                          </div>
                          <div>
                            <p className="text-xs text-muted-foreground uppercase tracking-wide mb-1">
                              Quando
                            </p>
                            <p className="text-sm flex items-center gap-1">
                              <Clock className="h-3 w-3" />
                              {errorItem.timestamp}
                            </p>
                          </div>
                        </div>

                        {errorItem.endpoint && (
                          <div className="mt-4">
                            <p className="text-xs text-muted-foreground uppercase tracking-wide mb-1">
                              Trace ID
                            </p>
                            <p className="text-sm font-mono bg-muted px-2 py-1 rounded break-all">
                              {errorItem.endpoint}
                            </p>
                          </div>
                        )}
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </TabsContent>
      </Tabs>

      {/* Drill-down Sheet */}
      <TurnDrillDown
        turn={selectedTurn}
        open={drillDownOpen}
        onOpenChange={setDrillDownOpen}
      />
    </div>
  );
}

// ─── Subcomponentes ──────────────────────────────────────────────────────────

function KPICard({
  icon: Icon,
  label,
  value,
}: {
  icon: React.ElementType;
  label: string;
  value: string;
}) {
  return (
    <div className="rounded-lg border bg-card p-4">
      <div className="flex items-center gap-3">
        <div className="rounded-lg bg-primary/10 p-2.5">
          <Icon className="h-5 w-5 text-primary" />
        </div>
        <div>
          <p className="text-xs text-muted-foreground">{label}</p>
          <p className="text-2xl font-bold">{value}</p>
        </div>
      </div>
    </div>
  );
}

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}K`;
  return n.toString();
}
