import { useState } from "react";
import { useTopUsers } from "@/hooks/useAnalyticsData";
import { User, MessageSquare, Heart, Trophy, RefreshCw, Download, Loader2 } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Button } from "@/components/ui/button";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";

interface UserExportData {
  nome: string;
  telefone: string;
  cidade_residencia: string;
  local_interesse: string;
  mensagens: number;
  etapa_funil: string;
  curso_interesse: string;
  favoritos: number;
}

export function TopUsersChart() {
  const [isExporting, setIsExporting] = useState(false);
  const { data: users, isLoading, error } = useTopUsers();

  const handleExportMatchRealizado = async () => {
    setIsExporting(true);
    try {
      const { data, error: exportError } = await supabase.functions.invoke("analytics-top-users-export");

      if (exportError) {
        console.error("Export error:", exportError);
        toast.error("Erro ao exportar dados");
        return;
      }

      const exportData = data as UserExportData[];

      if (!exportData || exportData.length === 0) {
        toast.warning("Nenhum usuário com Match Realizado encontrado");
        return;
      }

      // Generate CSV
      const headers = ["Nome", "Telefone", "Cidade de Residência", "Local de Interesse", "Etapa do Funil", "Curso de Interesse", "Favoritos", "Total de Mensagens"];
      const rows = exportData.map((user) => [
        user.nome,
        user.telefone,
        user.cidade_residencia,
        user.local_interesse,
        user.etapa_funil,
        user.curso_interesse,
        user.favoritos.toString(),
        user.mensagens.toString(),
      ]);

      const csvContent = [
        headers.join(","),
        ...rows.map((row) =>
          row.map((cell) => `"${(cell || "").replace(/"/g, '""')}"`).join(",")
        ),
      ].join("\n");

      // Add BOM for Excel UTF-8 compatibility
      const BOM = "\uFEFF";
      const blob = new Blob([BOM + csvContent], { type: "text/csv;charset=utf-8;" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.setAttribute("href", url);
      link.setAttribute("download", `top_users_match_realizado_${new Date().toISOString().split("T")[0]}.csv`);
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      URL.revokeObjectURL(url);

      toast.success(`Exportados ${exportData.length} usuários com Match Realizado`);
    } catch (err) {
      console.error("Export error:", err);
      toast.error("Erro ao exportar dados");
    } finally {
      setIsExporting(false);
    }
  };

  if (isLoading) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Maior Volume de Mensagens</h3>
          <p className="text-sm text-muted-foreground">Usuários com mais interações no chat</p>
        </div>
        <div className="space-y-3">
          {[...Array(5)].map((_, i) => (
            <Skeleton key={i} className="h-16 w-full" />
          ))}
        </div>
      </div>
    );
  }

  if (error || !users || users.length === 0) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Maior Volume de Mensagens</h3>
          <p className="text-sm text-muted-foreground">Usuários com mais interações no chat</p>
        </div>
        <div className="flex flex-col items-center justify-center py-12 text-muted-foreground">
          <User className="h-12 w-12 mb-4 opacity-50" />
          <p>Nenhum dado de usuário disponível</p>
        </div>
      </div>
    );
  }

  const maxScore = users[0]?.score || 1;

  return (
    <div className="chart-container">
      <div className="mb-6 flex items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Maior Volume de Mensagens</h3>
          <p className="text-sm text-muted-foreground">
            Top {users.length} usuários com mais interações no chat
          </p>
        </div>
        <Button
          variant="outline"
          size="sm"
          onClick={handleExportMatchRealizado}
          disabled={isExporting}
          className="shrink-0"
        >
          {isExporting ? (
            <Loader2 className="h-4 w-4 animate-spin mr-2" />
          ) : (
            <Download className="h-4 w-4 mr-2" />
          )}
          Match Realizado
        </Button>
      </div>

      <ScrollArea className="h-[500px] pr-4">
        <div className="space-y-3">
          {users.map((user, index) => {
            const percentage = (user.score / maxScore) * 100;
            const isTop3 = index < 3;

            return (
              <div
                key={user.id}
                className={cn(
                  "relative rounded-lg border p-4 transition-all hover:shadow-md opacity-0 animate-fade-in",
                  isTop3 && "border-primary/30 bg-primary/5"
                )}
                style={{ animationDelay: `${Math.min(index * 50, 500)}ms` }}
              >
                <div className="flex items-center gap-4">
                  <div className={cn(
                    "flex h-8 w-8 items-center justify-center rounded-full text-sm font-bold",
                    index === 0 && "bg-amber-500 text-white",
                    index === 1 && "bg-slate-400 text-white",
                    index === 2 && "bg-amber-700 text-white",
                    index > 2 && "bg-muted text-muted-foreground"
                  )}>
                    {index === 0 ? <Trophy className="h-4 w-4" /> : index + 1}
                  </div>

                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="font-medium truncate">{user.name}</span>
                      {user.sessions > 1 && (
                        <span className="text-xs px-2 py-0.5 rounded-full bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400 font-medium">
                          Recorrente
                        </span>
                      )}
                    </div>
                    <div className="flex items-center gap-4 mt-1 text-xs text-muted-foreground">
                      <span className="flex items-center gap-1">
                        <RefreshCw className="h-3 w-3" />
                        {user.sessions} {user.sessions === 1 ? 'acesso' : 'acessos'}
                      </span>
                      <span className="flex items-center gap-1">
                        <MessageSquare className="h-3 w-3" />
                        {user.messages} msgs
                      </span>
                      <span className="flex items-center gap-1">
                        <Heart className="h-3 w-3" />
                        {user.favorites} favs
                      </span>
                    </div>
                  </div>

                  <div className="text-right">
                    <span className="text-lg font-bold text-primary">{user.messages}</span>
                    <p className="text-xs text-muted-foreground">mensagens</p>
                  </div>
                </div>

                <div className="mt-3 h-1.5 w-full rounded-full bg-muted overflow-hidden">
                  <div
                    className="h-full rounded-full bg-gradient-to-r from-primary to-chart-2 transition-all duration-500"
                    style={{ width: `${percentage}%` }}
                  />
                </div>
              </div>
            );
          })}
        </div>
      </ScrollArea>
    </div>
  );
}
