import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { AlertTriangle, Info, AlertCircle, X } from 'lucide-react';
import { toast } from 'sonner';
import {
  listPendingAlerts,
  dismissAlert,
  resolveAlert,
  type AdminAlert,
  type AlertSeverity,
} from '@/services/adminAlertsService';
import { updateProgramStatus, type ProgramStatus } from '@/services/programsService';
import { useAuth } from '@/context/AuthContext';

const SEVERITY_CONFIG: Record<AlertSeverity, { icon: typeof Info; className: string; border: string }> = {
  info:     { icon: Info,          className: 'text-blue-600 bg-blue-100',     border: 'border-blue-200' },
  warning:  { icon: AlertTriangle, className: 'text-yellow-600 bg-yellow-100', border: 'border-yellow-200' },
  critical: { icon: AlertCircle,   className: 'text-red-600 bg-red-100',       border: 'border-red-200' },
};

export function ActionCenter() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { user } = useAuth();

  const { data: alerts = [], isLoading } = useQuery({
    queryKey: ['admin-alerts-pending'],
    queryFn: () => listPendingAlerts(10),
    refetchInterval: 60_000,
  });

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ['admin-alerts-pending'] });

  const dismissMutation = useMutation({
    mutationFn: dismissAlert,
    onSuccess: invalidate,
    onError: () => toast.error('Erro ao dispensar alerta.'),
  });

  const resolveProgramStatusMutation = useMutation({
    mutationFn: async ({ alertId, programId, status }: { alertId: string; programId: string; status: ProgramStatus }) => {
      if (!user?.id) throw new Error('Usuário não autenticado');
      await updateProgramStatus(programId, status);
      await resolveAlert(alertId, user.id);
    },
    onSuccess: () => {
      invalidate();
      toast.success('Status atualizado com sucesso!');
    },
    onError: (err: Error) => toast.error(`Erro ao atualizar: ${err.message}`),
  });

  const handleAction = (alert: AdminAlert) => {
    const meta = alert.action_metadata as Record<string, any> | null;
    
    const actions: Record<string, () => void> = {
      navigate: () => meta?.route && navigate(meta.route),
      activate_opportunities: () => navigate('/partner-opportunities'),
      deactivate_opportunities: () => navigate('/partner-opportunities'),
      update_program_status: () => {
        if (!alert.entity_id || !meta?.status) return toast.error('Dados insuficientes.');
        resolveProgramStatusMutation.mutate({ alertId: alert.id, programId: alert.entity_id, status: meta.status as ProgramStatus });
      }
    };

    const action = actions[alert.action_type || ''];
    if (action) action();
    else toast.info(alert.action_label || 'Ação não configurada');
  };

  const generateDebugAlert = async () => {
    try {
      const { supabase } = await import('@/integrations/supabase/client');
      const { error } = await supabase.from('admin_alerts').insert({
        alert_type: 'program_start_incoming', severity: 'info', title: `Deseja abrir o SiSU 2026.1?`,
        description: `As inscrições começam em breve.`, entity_type: 'program', entity_id: '649fbc7d-e173-4d30-a0f7-39ce68dca1b6',
        action_label: 'Confirmar', action_type: 'update_program_status', action_metadata: { status: 'opened' },
      });
      if (error) throw error;
      toast.success('Alerta de teste gerado!');
      invalidate();
    } catch (e: any) {
      toast.error(`Erro ao gerar: ${e.message}`);
    }
  };

  if (isLoading) return null;

  if (alerts.length === 0) {
    if (!import.meta.env.DEV) return null;
    return (
      <section className="space-y-3">
        <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Action Center (Debug)</h3>
        <button onClick={generateDebugAlert} className="px-4 py-2 bg-blue-100 text-blue-700 rounded-lg text-sm font-semibold hover:bg-blue-200 transition-colors">
          Gerar Alerta de Teste
        </button>
      </section>
    );
  }

  const isPending = resolveProgramStatusMutation.isPending || dismissMutation.isPending;

  return (
    <section className="space-y-3">
      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Action Center</h3>
      <div className="space-y-2">
        {alerts.map(alert => (
          <AlertItem 
            key={alert.id} 
            alert={alert} 
            isPending={isPending} 
            onAction={() => handleAction(alert)} 
            onDismiss={() => dismissMutation.mutate(alert.id)} 
          />
        ))}
      </div>
    </section>
  );
}

function AlertItem({ alert, isPending, onAction, onDismiss }: { alert: AdminAlert, isPending: boolean, onAction: () => void, onDismiss: () => void }) {
  const { icon: Icon, className, border } = SEVERITY_CONFIG[alert.severity];

  return (
    <div className={`flex items-start gap-3 rounded-xl border p-4 bg-white ${border}`}>
      <div className={`rounded-lg p-2 ${className}`}>
        <Icon className="h-4 w-4" />
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-semibold text-gray-800">{alert.title}</p>
        {alert.description && <p className="text-xs text-gray-500 mt-0.5">{alert.description}</p>}
      </div>
      <div className="flex items-center gap-2 shrink-0">
        {alert.action_label && (
          <button
            onClick={onAction}
            disabled={isPending}
            className="px-3 py-1.5 text-xs font-semibold text-blue-700 bg-blue-100 rounded-full hover:bg-blue-200 transition-colors disabled:opacity-50"
          >
            {alert.action_label}
          </button>
        )}
        <button
          onClick={onDismiss}
          disabled={isPending}
          className="p-1 text-gray-400 hover:text-gray-600 rounded transition-colors disabled:opacity-50"
          title="Dispensar"
        >
          <X className="h-4 w-4" />
        </button>
      </div>
    </div>
  );
}
