import { useState } from "react";
import { Download, Loader2, Users } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";

interface InactiveUsersExportButtonProps {
  inactiveCount: number;
}

interface ExportData {
  users: {
    nome: string;
    telefone: string;
    cidade: string;
    curso: string;
    etapa: string;
    data_cadastro: string;
  }[];
  summary: {
    total_registered: number;
    active_users: number;
    inactive_users: number;
  };
}

export function InactiveUsersExportButton({ inactiveCount }: InactiveUsersExportButtonProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [exportData, setExportData] = useState<ExportData | null>(null);

  const fetchExportData = async () => {
    setIsLoading(true);
    try {
      const { data, error } = await supabase.functions.invoke('analytics-export-inactive');
      
      if (error) throw error;
      setExportData(data);
    } catch (error) {
      console.error('Error fetching inactive users:', error);
      toast.error('Erro ao carregar dados para exportação');
    } finally {
      setIsLoading(false);
    }
  };

  const handleOpenChange = (open: boolean) => {
    setIsOpen(open);
    if (open && !exportData) {
      fetchExportData();
    }
  };

  const downloadCSV = () => {
    if (!exportData?.users || exportData.users.length === 0) {
      toast.error('Nenhum dado para exportar');
      return;
    }

    const headers = ['Nome', 'Telefone', 'Cidade', 'Curso', 'Etapa do Funil', 'Data de Cadastro'];
    const rows = exportData.users.map(user => [
      user.nome,
      user.telefone,
      user.cidade,
      user.curso,
      user.etapa,
      user.data_cadastro,
    ]);

    const csvContent = [
      headers.join(','),
      ...rows.map(row => row.map(cell => `"${(cell || '').replace(/"/g, '""')}"`).join(','))
    ].join('\n');

    const blob = new Blob(['\ufeff' + csvContent], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `usuarios-inativos-${new Date().toISOString().split('T')[0]}.csv`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);

    toast.success(`CSV exportado com ${exportData.users.length} usuários inativos`);
    setIsOpen(false);
  };

  return (
    <Dialog open={isOpen} onOpenChange={handleOpenChange}>
      <DialogTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="h-5 w-5 text-muted-foreground hover:text-foreground"
          title="Exportar usuários inativos"
        >
          <Download className="h-3 w-3" />
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Users className="h-5 w-5 text-muted-foreground" />
            Exportar Usuários Inativos
          </DialogTitle>
          <DialogDescription>
            Usuários que não tiveram atividade nos últimos 7 dias
          </DialogDescription>
        </DialogHeader>

        <div className="py-4">
          {isLoading ? (
            <div className="flex items-center justify-center py-8">
              <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
            </div>
          ) : exportData ? (
            <div className="space-y-4">
              <div className="grid grid-cols-2 gap-4">
                <div className="rounded-lg bg-muted/50 p-4 text-center">
                  <p className="text-2xl font-bold text-foreground">
                    {exportData.summary.inactive_users.toLocaleString()}
                  </p>
                  <p className="text-xs text-muted-foreground">Usuários Inativos</p>
                </div>
                <div className="rounded-lg bg-muted/50 p-4 text-center">
                  <p className="text-2xl font-bold text-foreground">
                    {exportData.summary.total_registered.toLocaleString()}
                  </p>
                  <p className="text-xs text-muted-foreground">Total Cadastrados</p>
                </div>
              </div>

              <div className="text-xs text-muted-foreground space-y-1">
                <p>O CSV incluirá:</p>
                <ul className="list-disc list-inside pl-2 space-y-0.5">
                  <li>Nome</li>
                  <li>Telefone</li>
                  <li>Cidade</li>
                  <li>Curso de Interesse</li>
                  <li>Etapa do Funil</li>
                  <li>Data de Cadastro</li>
                </ul>
              </div>

              <Button 
                onClick={downloadCSV} 
                className="w-full gap-2"
                disabled={exportData.users.length === 0}
              >
                <Download className="h-4 w-4" />
                Baixar CSV ({exportData.users.length} usuários)
              </Button>
            </div>
          ) : (
            <div className="text-center py-8 text-muted-foreground">
              Erro ao carregar dados
            </div>
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}
