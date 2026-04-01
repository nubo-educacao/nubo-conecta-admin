import { useState } from "react";
import { UserCheck, ChevronRight, Copy, Check, Download, Loader2 } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { HelpCircle } from "lucide-react";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Button } from "@/components/ui/button";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";

interface PowerUser {
  userId: string;
  userName: string;
  userPhone: string;
  accessCount: number;
}

interface PowerUsersCardProps {
  count: number;
  change?: number;
  powerUsersList: PowerUser[];
}

interface ExportUser {
  nome: string;
  telefone: string;
  cidadeResidencia: string;
  localInteresse: string;
  cursoInteresse: string;
  etapaFunil: string;
  favoritos: number;
  totalAcessos: number;
}

export function PowerUsersCard({ count, change, powerUsersList }: PowerUsersCardProps) {
  const [open, setOpen] = useState(false);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [isExporting, setIsExporting] = useState(false);
  const isPositive = change && change > 0;
  const isNegative = change && change < 0;

  // Format phone for display (e.g., 5581981846070 -> +55 81 98184-6070)
  const formatPhone = (phone: string) => {
    if (!phone) return '';
    // Remove any non-digits
    const digits = phone.replace(/\D/g, '');
    if (digits.length === 13) {
      return `+${digits.slice(0, 2)} ${digits.slice(2, 4)} ${digits.slice(4, 9)}-${digits.slice(9)}`;
    }
    if (digits.length === 12) {
      return `+${digits.slice(0, 2)} ${digits.slice(2, 4)} ${digits.slice(4, 8)}-${digits.slice(8)}`;
    }
    return phone;
  };

  const copyToClipboard = async (phone: string, userId: string) => {
    try {
      await navigator.clipboard.writeText(phone);
      setCopiedId(userId);
      toast.success('Telefone copiado!');
      setTimeout(() => setCopiedId(null), 2000);
    } catch (err) {
      toast.error('Erro ao copiar');
    }
  };

  const handleExportCSV = async () => {
    setIsExporting(true);
    try {
      const { data, error } = await supabase.functions.invoke('analytics-power-users-export');
      
      if (error) throw error;
      
      const users: ExportUser[] = data.users || [];
      
      if (users.length === 0) {
        toast.error('Nenhum Power User encontrado para exportar');
        return;
      }

      // CSV header
      const headers = [
        'Nome',
        'Telefone',
        'Cidade de Residência',
        'Local de Interesse',
        'Curso de Interesse',
        'Etapa do Funil',
        'Favoritos',
        'Total de Acessos'
      ];

      // CSV rows
      const rows = users.map(user => [
        user.nome,
        user.telefone,
        user.cidadeResidencia,
        user.localInteresse,
        user.cursoInteresse,
        user.etapaFunil,
        user.favoritos.toString(),
        user.totalAcessos.toString()
      ]);

      // Build CSV content with BOM for Excel compatibility
      const csvContent = '\uFEFF' + [
        headers.join(';'),
        ...rows.map(row => row.map(cell => `"${(cell || '').replace(/"/g, '""')}"`).join(';'))
      ].join('\n');

      // Create and download file
      const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = `power-users-${new Date().toISOString().split('T')[0]}.csv`;
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      URL.revokeObjectURL(url);

      toast.success(`${users.length} Power Users exportados com sucesso!`);
    } catch (error) {
      console.error('Export error:', error);
      toast.error('Erro ao exportar Power Users');
    } finally {
      setIsExporting(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <div 
          className={cn(
            "stat-card cursor-pointer transition-all hover:scale-[1.02] hover:shadow-lg",
            "before:bg-gradient-to-r before:from-chart-3 before:to-violet-400"
          )}
        >
          <div className="flex items-start justify-between">
            <div className="space-y-1">
              <div className="flex items-center gap-1.5">
                <p className="text-sm font-medium text-muted-foreground">Power Users</p>
                <TooltipProvider>
                  <Tooltip>
                    <TooltipTrigger asChild>
                      <HelpCircle className="h-3.5 w-3.5 text-muted-foreground/60 cursor-help" />
                    </TooltipTrigger>
                    <TooltipContent side="bottom" className="max-w-xs">
                      <p className="text-xs">Usuários recorrentes com 2 ou mais sessões (considerando todo o período). Clique para ver a lista.</p>
                    </TooltipContent>
                  </Tooltip>
                </TooltipProvider>
              </div>
              <p className="text-3xl font-bold font-display tracking-tight">
                {count.toLocaleString()}
              </p>
            </div>
            <div className="flex items-center gap-2">
              <div className="rounded-xl p-3 bg-chart-3/10 text-chart-3">
                <UserCheck className="h-5 w-5" />
              </div>
              <ChevronRight className="h-4 w-4 text-muted-foreground" />
            </div>
          </div>
          
          {change !== undefined && (
            <div className="mt-4 flex items-center gap-2">
              <span
                className={cn(
                  "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
                  isPositive && "bg-success/10 text-success",
                  isNegative && "bg-destructive/10 text-destructive",
                  !isPositive && !isNegative && "bg-muted text-muted-foreground"
                )}
              >
                {isPositive && "+"}
                {change}%
              </span>
              <span className="text-xs text-muted-foreground">
                vs período anterior
              </span>
            </div>
          )}
        </div>
      </DialogTrigger>
      
      <DialogContent className="max-w-md">
        <DialogHeader>
          <div className="flex items-center justify-between">
            <DialogTitle className="flex items-center gap-2">
              <UserCheck className="h-5 w-5 text-chart-3" />
              Power Users - Usuários Recorrentes
            </DialogTitle>
            <Button
              variant="outline"
              size="sm"
              onClick={handleExportCSV}
              disabled={isExporting}
              className="ml-4 gap-1"
            >
              {isExporting ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Download className="h-4 w-4" />
              )}
              <span className="ml-1.5">Exportar CSV</span>
            </Button>
          </div>
        </DialogHeader>
        
        <div className="text-sm text-muted-foreground mb-4">
          {powerUsersList.length > 0 ? (
            <p>Top {powerUsersList.length} usuários com mais sessões (todo o período)</p>
          ) : (
            <p>Nenhum usuário recorrente encontrado</p>
          )}
        </div>
        
        <ScrollArea className="h-[400px] pr-2">
          <div className="space-y-2">
            {powerUsersList.map((user, index) => (
              <div
                key={user.userId}
                className="flex items-start gap-2 p-3 rounded-lg bg-muted/50 hover:bg-muted transition-colors"
              >
                <span className="flex-shrink-0 flex items-center justify-center w-6 h-6 rounded-full bg-chart-3/20 text-chart-3 text-xs font-bold mt-0.5">
                  {index + 1}
                </span>
                <div className="flex-1 min-w-0 overflow-hidden">
                  <div className="flex items-start justify-between gap-2">
                    <p className="text-sm font-medium truncate flex-1" title={user.userName}>
                      {user.userName}
                    </p>
                    <div className="flex-shrink-0 bg-chart-3/10 rounded-md px-2 py-0.5 flex items-center gap-1">
                      <span className="text-sm font-bold text-chart-3">
                        {user.accessCount}
                      </span>
                      <span className="text-[10px] text-chart-3/80">acessos</span>
                    </div>
                  </div>
                  {user.userPhone ? (
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        copyToClipboard(user.userPhone, user.userId);
                      }}
                      className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground transition-colors group mt-0.5"
                    >
                      <span>{formatPhone(user.userPhone)}</span>
                      {copiedId === user.userId ? (
                        <Check className="h-3 w-3 text-success" />
                      ) : (
                        <Copy className="h-3 w-3 opacity-0 group-hover:opacity-100 transition-opacity" />
                      )}
                    </button>
                  ) : (
                    <span className="text-xs text-muted-foreground/60 mt-0.5">Telefone não disponível</span>
                  )}
                </div>
              </div>
            ))}
          </div>
        </ScrollArea>
      </DialogContent>
    </Dialog>
  );
}
