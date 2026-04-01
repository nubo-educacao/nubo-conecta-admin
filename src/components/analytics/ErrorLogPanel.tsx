import { AlertCircle, AlertTriangle, Info, Clock, ChevronRight, CheckCircle } from "lucide-react";
import { cn } from "@/lib/utils";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useErrorLogs } from "@/hooks/useAnalyticsData";
import { Skeleton } from "@/components/ui/skeleton";
import { Link } from "react-router-dom";

const typeConfig = {
  error: { icon: AlertCircle, bgClass: "bg-destructive/10", textClass: "text-destructive", badgeClass: "bg-destructive/10 text-destructive" },
  warning: { icon: AlertTriangle, bgClass: "bg-warning/10", textClass: "text-warning", badgeClass: "bg-warning/10 text-warning" },
  info: { icon: Info, bgClass: "bg-primary/10", textClass: "text-primary", badgeClass: "bg-primary/10 text-primary" },
};

export function ErrorLogPanel() {
  const { data: errors, isLoading, error } = useErrorLogs();

  if (isLoading) {
    return (
      <div className="chart-container flex flex-col">
        <div className="mb-4 flex items-center justify-between">
          <div className="flex flex-col gap-1">
            <h3 className="text-lg font-semibold font-display">Logs de Erros</h3>
            <p className="text-sm text-muted-foreground">Últimos incidentes registrados</p>
          </div>
        </div>
        <div className="space-y-3">{[...Array(4)].map((_, i) => <Skeleton key={i} className="h-20 w-full" />)}</div>
      </div>
    );
  }

  if (error || !errors || errors.length === 0) {
    return (
      <div className="chart-container flex flex-col">
        <div className="mb-4 flex items-center justify-between">
          <div className="flex flex-col gap-1">
            <h3 className="text-lg font-semibold font-display">Logs de Erros</h3>
            <p className="text-sm text-muted-foreground">Últimos incidentes registrados</p>
          </div>
        </div>
        <div className="flex flex-col items-center justify-center py-12 text-muted-foreground">
          <CheckCircle className="h-12 w-12 mb-4 text-success opacity-70" />
          <p className="font-medium text-foreground">Nenhum erro registrado!</p>
          <p className="text-sm mt-1">Tudo funcionando normalmente</p>
        </div>
      </div>
    );
  }

  return (
    <div className="chart-container flex flex-col">
      <div className="mb-4 flex items-center justify-between">
        <div className="flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Logs de Erros</h3>
          <p className="text-sm text-muted-foreground">Últimos {errors.length} incidentes</p>
        </div>
        <Link to="/errors" className="flex items-center gap-1 text-sm font-medium text-primary hover:underline">
          Ver todos <ChevronRight className="h-4 w-4" />
        </Link>
      </div>
      
      <ScrollArea className="flex-1 -mx-2 px-2">
        <div className="space-y-3">
          {errors.map((errorItem, index) => {
            const config = typeConfig[errorItem.type];
            const Icon = config.icon;
            return (
              <div key={errorItem.id} className={cn("group cursor-pointer rounded-lg border p-4 transition-all hover:shadow-md opacity-0 animate-fade-in")} style={{ animationDelay: `${index * 100}ms` }}>
                <div className="flex items-start gap-3">
                  <div className={cn("rounded-lg p-2", config.bgClass)}><Icon className={cn("h-4 w-4", config.textClass)} /></div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <p className="font-medium text-sm truncate">{errorItem.message}</p>
                      {errorItem.count > 1 && <span className={cn("error-badge", config.badgeClass)}>×{errorItem.count}</span>}
                    </div>
                    <p className="mt-1 text-xs text-muted-foreground font-mono truncate">{errorItem.errorType}</p>
                    <div className="mt-2 flex items-center gap-1 text-xs text-muted-foreground"><Clock className="h-3 w-3" />{errorItem.time}</div>
                  </div>
                  <ChevronRight className="h-4 w-4 text-muted-foreground opacity-0 group-hover:opacity-100 transition-opacity" />
                </div>
              </div>
            );
          })}
        </div>
      </ScrollArea>
    </div>
  );
}
