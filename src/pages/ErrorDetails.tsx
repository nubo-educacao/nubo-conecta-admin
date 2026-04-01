import { useState } from "react";
import { Link } from "react-router-dom";
import { 
  AlertCircle, 
  AlertTriangle, 
  Info, 
  Clock, 
  ChevronLeft,
  Filter,
  RefreshCw,
  CheckCircle,
  XCircle
} from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { useErrorLogs } from "@/hooks/useAnalyticsData";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

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

export default function ErrorDetails() {
  const { data: errors, isLoading, error, refetch, isRefetching } = useErrorLogs();
  const [filterType, setFilterType] = useState<string>("all");
  const [filterStatus, setFilterStatus] = useState<string>("all");

  const filteredErrors = errors?.filter((err) => {
    if (filterType !== "all" && err.type !== filterType) return false;
    if (filterStatus === "resolved" && !err.resolved) return false;
    if (filterStatus === "unresolved" && err.resolved) return false;
    return true;
  });

  return (
    <div className="min-h-screen bg-background">
      {/* Header */}
      <header className="sticky top-0 z-50 border-b border-border bg-card/80 backdrop-blur-lg">
        <div className="container py-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-4">
              <Link to="/">
                <Button variant="ghost" size="icon">
                  <ChevronLeft className="h-5 w-5" />
                </Button>
              </Link>
              <div>
                <h1 className="text-xl font-bold font-display">Detalhamento de Erros</h1>
                <p className="text-sm text-muted-foreground">
                  Histórico completo de incidentes
                </p>
              </div>
            </div>
            <Button 
              variant="outline" 
              size="sm" 
              onClick={() => refetch()}
              disabled={isRefetching}
            >
              <RefreshCw className={cn("h-4 w-4 mr-2", isRefetching && "animate-spin")} />
              Atualizar
            </Button>
          </div>
        </div>
      </header>

      <main className="container py-6 space-y-6">
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
                  {errors?.filter(e => e.type === "error").length || 0}
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
                  {errors?.filter(e => e.type === "warning").length || 0}
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
                  {errors?.filter(e => e.resolved).length || 0}
                </p>
                <p className="text-sm text-muted-foreground">Resolvidos</p>
              </div>
            </div>
          </div>
        </div>

        {/* Error List */}
        {isLoading ? (
          <div className="space-y-4">
            {[...Array(5)].map((_, i) => (
              <Skeleton key={i} className="h-24 w-full" />
            ))}
          </div>
        ) : error ? (
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
                        <Badge variant={config.badgeVariant}>
                          {config.label}
                        </Badge>
                        <Badge variant={errorItem.resolved ? "outline" : "secondary"}>
                          {errorItem.resolved ? (
                            <><CheckCircle className="h-3 w-3 mr-1" /> Resolvido</>
                          ) : (
                            <><XCircle className="h-3 w-3 mr-1" /> Pendente</>
                          )}
                        </Badge>
                      </div>

                      <h3 className="font-semibold text-lg mb-2">
                        {errorItem.message}
                      </h3>

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
      </main>
    </div>
  );
}
