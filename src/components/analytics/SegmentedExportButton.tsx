import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Download, Loader2, FileSpreadsheet } from 'lucide-react';
import { supabase } from '@/integrations/supabase/client';
import { toast } from 'sonner';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog';

interface UserExportRow {
  nome: string;
  telefone: string;
  cidade: string;
  curso: string;
  etapa: string;
  data_cadastro: string;
}

interface ExportData {
  aba1_engajados_foco: UserExportRow[];
  aba2_engajados_todos: UserExportRow[];
  aba3_desengajados_foco: UserExportRow[];
  summary: {
    total_users: number;
    aba1_count: number;
    aba2_count: number;
    aba3_count: number;
  };
}

const SegmentedExportButton = () => {
  const [isLoading, setIsLoading] = useState(false);
  const [exportData, setExportData] = useState<ExportData | null>(null);
  const [isOpen, setIsOpen] = useState(false);

  const fetchExportData = async () => {
    setIsLoading(true);
    try {
      const { data, error } = await supabase.functions.invoke('analytics-segmented-export');
      
      if (error) throw error;
      
      setExportData(data);
      toast.success('Dados carregados com sucesso!');
    } catch (error) {
      console.error('Error fetching export data:', error);
      toast.error('Erro ao carregar dados para exportação');
    } finally {
      setIsLoading(false);
    }
  };

  const downloadCSV = (data: UserExportRow[], filename: string) => {
    const headers = ['Nome', 'Telefone', 'Cidade', 'Curso', 'Etapa', 'Data de Cadastro'];
    const csvRows = [
      headers.join(','),
      ...data.map(row => [
        `"${row.nome || ''}"`,
        `"${row.telefone || ''}"`,
        `"${row.cidade || ''}"`,
        `"${row.curso || ''}"`,
        `"${row.etapa || ''}"`,
        `"${row.data_cadastro || ''}"`,
      ].join(','))
    ];
    
    const csvContent = csvRows.join('\n');
    const blob = new Blob(['\ufeff' + csvContent], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.setAttribute('href', url);
    link.setAttribute('download', filename);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
    
    toast.success(`${filename} baixado!`);
  };

  const downloadAllCSVs = () => {
    if (!exportData) return;
    
    downloadCSV(exportData.aba1_engajados_foco, 'aba1_engajados_pracas_foco.csv');
    setTimeout(() => {
      downloadCSV(exportData.aba2_engajados_todos, 'aba2_engajados_todos_locais.csv');
    }, 500);
    setTimeout(() => {
      downloadCSV(exportData.aba3_desengajados_foco, 'aba3_desengajados_pracas_foco.csv');
    }, 1000);
  };

  return (
    <Dialog open={isOpen} onOpenChange={setIsOpen}>
      <DialogTrigger asChild>
        <Button 
          variant="outline" 
          className="gap-2"
          onClick={() => {
            setIsOpen(true);
            if (!exportData) {
              fetchExportData();
            }
          }}
        >
          <FileSpreadsheet className="h-4 w-4" />
          Exportar Segmentado
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>Exportação Segmentada de Usuários</DialogTitle>
          <DialogDescription>
            Exporte os dados de usuários organizados em 3 planilhas para ações de CRM e WhatsApp.
          </DialogDescription>
        </DialogHeader>

        {isLoading ? (
          <div className="flex flex-col items-center justify-center py-8 gap-3">
            <Loader2 className="h-8 w-8 animate-spin text-primary" />
            <p className="text-sm text-muted-foreground">Processando dados...</p>
          </div>
        ) : exportData ? (
          <div className="space-y-4">
            <div className="grid gap-3">
              <div className="flex items-center justify-between p-3 bg-green-50 dark:bg-green-950/30 rounded-lg border border-green-200 dark:border-green-800">
                <div>
                  <p className="font-medium text-green-800 dark:text-green-200">
                    Aba 1: Engajados nas Praças Foco
                  </p>
                  <p className="text-sm text-green-600 dark:text-green-400">
                    PB, BA, RN, PE + Power Users (2+ acessos)
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    {exportData.summary.aba1_count} usuários
                  </p>
                </div>
                <Button 
                  size="sm" 
                  variant="outline"
                  className="gap-1"
                  onClick={() => downloadCSV(exportData.aba1_engajados_foco, 'aba1_engajados_pracas_foco.csv')}
                  disabled={exportData.aba1_engajados_foco.length === 0}
                >
                  <Download className="h-3 w-3" />
                  CSV
                </Button>
              </div>

              <div className="flex items-center justify-between p-3 bg-blue-50 dark:bg-blue-950/30 rounded-lg border border-blue-200 dark:border-blue-800">
                <div>
                  <p className="font-medium text-blue-800 dark:text-blue-200">
                    Aba 2: Engajados (Todos os Locais)
                  </p>
                  <p className="text-sm text-blue-600 dark:text-blue-400">
                    Power Users de qualquer localidade
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    {exportData.summary.aba2_count} usuários
                  </p>
                </div>
                <Button 
                  size="sm" 
                  variant="outline"
                  className="gap-1"
                  onClick={() => downloadCSV(exportData.aba2_engajados_todos, 'aba2_engajados_todos_locais.csv')}
                  disabled={exportData.aba2_engajados_todos.length === 0}
                >
                  <Download className="h-3 w-3" />
                  CSV
                </Button>
              </div>

              <div className="flex items-center justify-between p-3 bg-orange-50 dark:bg-orange-950/30 rounded-lg border border-orange-200 dark:border-orange-800">
                <div>
                  <p className="font-medium text-orange-800 dark:text-orange-200">
                    Aba 3: Desengajados nas Praças Foco
                  </p>
                  <p className="text-sm text-orange-600 dark:text-orange-400">
                    PB, BA, RN, PE com menos de 2 acessos
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    {exportData.summary.aba3_count} usuários
                  </p>
                </div>
                <Button 
                  size="sm" 
                  variant="outline"
                  className="gap-1"
                  onClick={() => downloadCSV(exportData.aba3_desengajados_foco, 'aba3_desengajados_pracas_foco.csv')}
                  disabled={exportData.aba3_desengajados_foco.length === 0}
                >
                  <Download className="h-3 w-3" />
                  CSV
                </Button>
              </div>
            </div>

            <div className="pt-2 border-t">
              <Button 
                className="w-full gap-2" 
                onClick={downloadAllCSVs}
              >
                <Download className="h-4 w-4" />
                Baixar Todas as Planilhas (3 CSVs)
              </Button>
            </div>

            <p className="text-xs text-muted-foreground text-center">
              Total: {exportData.summary.total_users} usuários processados
            </p>
          </div>
        ) : (
          <div className="flex flex-col items-center justify-center py-8 gap-3">
            <p className="text-sm text-muted-foreground">Erro ao carregar dados</p>
            <Button variant="outline" onClick={fetchExportData}>
              Tentar novamente
            </Button>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
};

export default SegmentedExportButton;
