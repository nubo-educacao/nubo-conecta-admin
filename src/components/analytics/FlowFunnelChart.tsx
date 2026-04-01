import { cn } from "@/lib/utils";
import { useFunnelData } from "@/hooks/useAnalyticsData";
import { Skeleton } from "@/components/ui/skeleton";
import { GitBranch, Info, Users, Download, Phone, BookOpen, RefreshCw } from "lucide-react";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Button } from "@/components/ui/button";
import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";

const colors = [
  "from-primary to-primary/80",
  "from-chart-2 to-chart-2/80",
  "from-chart-3 to-chart-3/80",
  "from-chart-4 to-chart-4/80",
  "from-chart-5 to-chart-5/80",
  "from-success to-success/80",
];

// Fallback descriptions if not provided by API
const funnelDescriptions: Record<string, string> = {
  'Cadastrados': 'Total de usuários na tabela user_profiles',
  'Onboarding Completo': 'Usuários com onboarding_completed = true',
  'Match Iniciado': 'Usuários que preencheram nota do ENEM em user_preferences',
  'Salvaram Favoritos': 'Usuários únicos que salvaram ao menos 1 favorito',
  'Fluxo Específico': 'Usuários que entraram em SISU, ProUni ou FIES workflow',
};

interface UserData {
  id: string;
  full_name: string | null;
  phone: string | null;
  city: string | null;
  created_at: string | null;
  course_interest: string[] | null;
}

interface FunnelStepLocal {
  etapa: string;
  valor: number;
  description?: string;
  user_ids?: string[];
  users?: UserData[];
}

function formatPhone(phone: string | null): string {
  if (!phone) return 'Não informado';
  // Remove non-digits
  const digits = phone.replace(/\D/g, '');
  // Format Brazilian phone: +55 11 99999-9999
  if (digits.length === 13) {
    return `+${digits.slice(0, 2)} ${digits.slice(2, 4)} ${digits.slice(4, 9)}-${digits.slice(9)}`;
  }
  if (digits.length === 12) {
    return `+${digits.slice(0, 2)} ${digits.slice(2, 4)} ${digits.slice(4, 8)}-${digits.slice(8)}`;
  }
  if (digits.length === 11) {
    return `(${digits.slice(0, 2)}) ${digits.slice(2, 7)}-${digits.slice(7)}`;
  }
  if (digits.length === 10) {
    return `(${digits.slice(0, 2)}) ${digits.slice(2, 6)}-${digits.slice(6)}`;
  }
  return phone;
}

export function FlowFunnelChart() {
  const { data: funnelData, isLoading, error, refetch, isRefetching } = useFunnelData();
  const [selectedStep, setSelectedStep] = useState<FunnelStepLocal | null>(null);
  const [funnelWithDetails, setFunnelWithDetails] = useState<FunnelStepLocal[]>([]);
  const [loadingDetails, setLoadingDetails] = useState(false);
  const [exporting, setExporting] = useState(false);

  // Refresh funnel details when main data is refetched
  const handleRefresh = async () => {
    await refetch();
    // Also refresh the detailed data
    fetchFunnelWithDetails();
  };

  const fetchFunnelWithDetails = async () => {
    setLoadingDetails(true);
    try {
      console.log('Fetching funnel with details...');
      const { data, error } = await supabase.functions.invoke('analytics-funnel', {
        body: { details: true }
      });
      
      if (error) {
        console.error('Error from analytics-funnel:', error);
        toast.error('Erro ao carregar detalhes do funil');
        return;
      }
      
      if (data && Array.isArray(data)) {
        console.log('Funnel with details loaded:', data.length, 'steps');
        console.log('First step has', data[0]?.users?.length || 0, 'users');
        setFunnelWithDetails(data);
      } else {
        console.warn('Unexpected data format from analytics-funnel:', data);
      }
    } catch (e) {
      console.error('Exception fetching funnel details:', e);
      toast.error('Erro ao carregar detalhes do funil');
    } finally {
      setLoadingDetails(false);
    }
  };

  // Fetch funnel data with full user details for drill-down
  useEffect(() => {
    fetchFunnelWithDetails();
  }, []);

  // Get users for selected step from cached data
  const getSelectedStepUsers = (): UserData[] => {
    if (!selectedStep) return [];
    
    // Find the step in funnelWithDetails
    const stepWithDetails = funnelWithDetails.find(s => s.etapa === selectedStep.etapa);
    
    if (stepWithDetails) {
      console.log(`Found step "${selectedStep.etapa}" with ${stepWithDetails.users?.length || 0} users`);
      return stepWithDetails.users || [];
    }
    
    console.log(`Step "${selectedStep.etapa}" not found in funnelWithDetails. Available steps:`, 
      funnelWithDetails.map(s => s.etapa));
    return [];
  };

  const selectedUsers = getSelectedStepUsers();

  // Export all funnel data to CSV
  const exportToCSV = async () => {
    if (funnelWithDetails.length === 0) {
      toast.error('Aguarde os dados carregarem');
      return;
    }

    setExporting(true);
    try {
      // Build CSV rows - each user appears with their most advanced stage
      const userStages = new Map<string, { user: UserData; stage: string; stageIndex: number }>();
      
      funnelWithDetails.forEach((step, index) => {
        const users = step.users || [];
        users.forEach(user => {
          const existing = userStages.get(user.id);
          // Keep the most advanced stage (higher index = more advanced)
          if (!existing || index > existing.stageIndex) {
            userStages.set(user.id, { user, stage: step.etapa, stageIndex: index });
          }
        });
      });

      // Create CSV content
      const headers = ['nome', 'telefone', 'cidade', 'curso', 'etapa', 'data_cadastro'];
      const rows = Array.from(userStages.values()).map(({ user, stage }) => [
        user.full_name || 'Anônimo',
        user.phone || '',
        user.city || '',
        user.course_interest?.join('; ') || '',
        stage,
        user.created_at ? new Date(user.created_at).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : ''
      ]);

      const csvContent = [
        headers.join(','),
        ...rows.map(row => row.map(cell => `"${String(cell).replace(/"/g, '""')}"`).join(','))
      ].join('\n');

      // Download file
      const blob = new Blob(['\ufeff' + csvContent], { type: 'text/csv;charset=utf-8;' });
      const link = document.createElement('a');
      link.href = URL.createObjectURL(blob);
      link.download = `funil-conversao-${new Date().toISOString().split('T')[0]}.csv`;
      link.click();
      URL.revokeObjectURL(link.href);

      toast.success(`Exportados ${userStages.size} usuários para CSV`);
    } catch (e) {
      console.error('Error exporting CSV:', e);
      toast.error('Erro ao exportar CSV');
    } finally {
      setExporting(false);
    }
  };

  if (isLoading) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Funil de Conversão</h3>
          <p className="text-sm text-muted-foreground">Drop-off nos principais fluxos</p>
        </div>
        <div className="space-y-4">
          {[...Array(5)].map((_, i) => (
            <Skeleton key={i} className="h-12 w-full" />
          ))}
        </div>
      </div>
    );
  }

  if (error || !funnelData || funnelData.length === 0) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Funil de Conversão</h3>
          <p className="text-sm text-muted-foreground">Drop-off nos principais fluxos</p>
        </div>
        <div className="flex flex-col items-center justify-center py-12 text-muted-foreground">
          <GitBranch className="h-12 w-12 mb-4 opacity-50" />
          <p>Nenhum dado de funil disponível</p>
        </div>
      </div>
    );
  }

  const maxValue = funnelData[0]?.valor ?? 1;

  let biggestDropIndex = -1;
  let biggestDrop = 0;
  funnelData.forEach((step, index) => {
    const currentVal = step?.valor ?? 0;
    const prevVal = funnelData[index - 1]?.valor ?? 0;
    if (index > 0 && prevVal > 0) {
      const drop = Math.round(((prevVal - currentVal) / prevVal) * 100);
      if (drop > biggestDrop) {
        biggestDrop = drop;
        biggestDropIndex = index;
      }
    }
  });

  const handleStepClick = (step: FunnelStepLocal) => {
    setSelectedStep(step);
  };

  return (
    <TooltipProvider>
      <div className="chart-container">
        <div className="mb-6 flex items-center justify-between">
          <div className="flex flex-col gap-1">
            <h3 className="text-lg font-semibold font-display">Funil de Conversão</h3>
            <p className="text-sm text-muted-foreground">Clique em uma etapa para ver os usuários</p>
          </div>
          <div className="flex items-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={handleRefresh}
              disabled={isRefetching || loadingDetails}
              title="Atualizar dados"
            >
              <RefreshCw className={cn("h-4 w-4", (isRefetching || loadingDetails) && "animate-spin")} />
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={exportToCSV}
              disabled={exporting || loadingDetails}
            >
              <Download className="h-4 w-4 mr-2" />
              {exporting ? 'Exportando...' : 'Exportar CSV'}
            </Button>
          </div>
        </div>

        {/* Visual Funnel - Fixed proportional widths for readability */}
        <div className="flex flex-col items-center space-y-1.5 py-4">
          {funnelData.map((step, index) => {
            const stepValue = step.valor ?? 0;
            const prevValue = funnelData[index - 1]?.valor ?? 0;
            const percentage = maxValue > 0 ? (stepValue / maxValue) * 100 : 0;
            
            // Use fixed proportional widths that decrease gradually for funnel visual
            // This ensures all steps are readable regardless of actual conversion rates
            const totalSteps = funnelData.length;
            const widthPercent = 100 - (index * (60 / totalSteps)); // From 100% to ~40%
            
            // Calculate drop-off from previous step
            const dropOff = index > 0 && prevValue > 0 ? Math.round(((prevValue - stepValue) / prevValue) * 100) : 0;

            const description = step.description || funnelDescriptions[step.etapa] || 'Etapa do funil';
            const isBottleneck = index === biggestDropIndex;

            return (
              <Tooltip key={step.etapa || index}>
                <TooltipTrigger asChild>
                  <div
                    className={cn(
                      "relative cursor-pointer transition-all duration-300 hover:scale-[1.02] hover:shadow-lg",
                      "opacity-0 animate-fade-in"
                    )}
                    style={{ 
                      animationDelay: `${index * 80}ms`,
                      width: `${widthPercent}%`,
                    }}
                    onClick={() => handleStepClick(step)}
                  >
                    {/* Funnel segment with trapezoid shape */}
                    <div 
                      className={cn(
                        "relative py-3 px-5 bg-gradient-to-r text-white shadow-md",
                        colors[index % colors.length],
                        isBottleneck && "ring-2 ring-destructive ring-offset-2 ring-offset-background"
                      )}
                      style={{
                        clipPath: index === funnelData.length - 1 
                          ? 'polygon(8% 0%, 92% 0%, 95% 100%, 5% 100%)' 
                          : 'polygon(0% 0%, 100% 0%, 96% 100%, 4% 100%)',
                        borderRadius: index === 0 ? '8px 8px 0 0' : index === funnelData.length - 1 ? '0 0 8px 8px' : '0'
                      }}
                    >
                      <div className="flex items-center justify-between relative z-10 gap-3">
                        <span className="font-medium text-sm whitespace-nowrap">{step.etapa || 'Etapa'}</span>
                        <div className="flex items-center gap-2 flex-shrink-0">
                          <span className="font-bold text-sm">{stepValue.toLocaleString()}</span>
                          <span className="text-xs opacity-80">({Math.round(percentage)}%)</span>
                          {dropOff > 0 && (
                            <span className={cn(
                              "text-xs px-1.5 py-0.5 rounded font-medium",
                              isBottleneck ? "bg-destructive text-destructive-foreground" : "bg-white/25"
                            )}>
                              -{dropOff}%
                            </span>
                          )}
                        </div>
                      </div>
                    </div>
                  </div>
                </TooltipTrigger>
                <TooltipContent side="right" className="max-w-xs">
                  <div className="space-y-1">
                    <p className="font-medium">{step.etapa}</p>
                    <p className="text-sm text-muted-foreground">{description}</p>
                    <p className="text-sm"><strong>{stepValue.toLocaleString()}</strong> usuários ({Math.round(percentage)}% do total)</p>
                    {dropOff > 0 && (
                      <p className="text-sm text-destructive">Queda de {dropOff}% da etapa anterior</p>
                    )}
                  </div>
                </TooltipContent>
              </Tooltip>
            );
          })}
        </div>

        {biggestDropIndex > 0 && (
          <div className="mt-4 p-4 rounded-lg bg-destructive/10 border border-destructive/20">
            <p className="text-sm">
              <span className="font-semibold text-destructive">⚠️ Maior gargalo:</span>{' '}
              Queda de <strong>{biggestDrop}%</strong> entre "{funnelData[biggestDropIndex - 1]?.etapa}" e "
              {funnelData[biggestDropIndex]?.etapa}".
            </p>
          </div>
        )}

        {/* Drill-down Dialog */}
        <Dialog open={!!selectedStep} onOpenChange={(open) => !open && setSelectedStep(null)}>
          <DialogContent className="max-w-lg">
            <DialogHeader>
              <DialogTitle className="flex items-center gap-2">
                <Users className="h-5 w-5" />
                {selectedStep?.etapa}
              </DialogTitle>
              <DialogDescription>
                {selectedStep?.description || funnelDescriptions[selectedStep?.etapa || '']}
              </DialogDescription>
            </DialogHeader>
            
            <div className="mt-4">
              <p className="text-sm text-muted-foreground mb-3">
                <strong>{selectedStep?.valor}</strong> usuários nesta etapa
              </p>
              
              {loadingDetails ? (
                <div className="space-y-2">
                  {[...Array(5)].map((_, i) => (
                    <Skeleton key={i} className="h-16 w-full" />
                  ))}
                </div>
              ) : selectedUsers.length > 0 ? (
                <ScrollArea className="h-[350px]">
                  <div className="space-y-2 pr-4">
                    {selectedUsers.map((user) => (
                      <div
                        key={user.id}
                        className="flex items-center justify-between p-3 rounded-lg border bg-card"
                      >
                        <div className="flex-1 min-w-0">
                          <p className="font-medium text-sm truncate">
                            {user.full_name || 'Usuário Anônimo'}
                          </p>
                          <p className="text-xs text-muted-foreground">
                            {user.city || 'Cidade não informada'}
                          </p>
                          <div className="flex items-center gap-1 mt-1">
                            <Phone className="h-3 w-3 text-muted-foreground" />
                            <span className="text-xs text-muted-foreground font-mono">
                              {formatPhone(user.phone)}
                            </span>
                          </div>
                          {user.course_interest && user.course_interest.length > 0 && (
                            <div className="flex items-center gap-1 mt-1">
                              <BookOpen className="h-3 w-3 text-primary" />
                              <span className="text-xs text-primary truncate max-w-[200px]">
                                {user.course_interest.slice(0, 2).join(', ')}
                                {user.course_interest.length > 2 && ` +${user.course_interest.length - 2}`}
                              </span>
                            </div>
                          )}
                        </div>
                        <div className="text-xs text-muted-foreground text-right">
                          {user.created_at
                            ? new Date(user.created_at).toLocaleDateString('pt-BR')
                            : '-'}
                        </div>
                      </div>
                    ))}
                  </div>
                </ScrollArea>
              ) : (
                <div className="flex flex-col items-center justify-center py-8 text-muted-foreground">
                  <Users className="h-8 w-8 mb-2 opacity-50" />
                  <p className="text-sm">Nenhum usuário encontrado</p>
                </div>
              )}
            </div>
          </DialogContent>
        </Dialog>
      </div>
    </TooltipProvider>
  );
}
