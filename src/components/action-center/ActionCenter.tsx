import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { AlertTriangle, Info, AlertCircle, X, CheckCircle } from 'lucide-react';
import { toast } from 'sonner';
import {
  listPendingAlerts,
  dismissAlert,
  type AdminAlert,
  type AlertSeverity,
} from '@/services/adminAlertsService';

const SEVERITY_CONFIG: Record<AlertSeverity, { icon: typeof Info; className: string; border: string }> = {
  info:     { icon: Info,          className: 'text-blue-600 bg-blue-100',     border: 'border-blue-200' },
  warning:  { icon: AlertTriangle, className: 'text-yellow-600 bg-yellow-100', border: 'border-yellow-200' },
  critical: { icon: AlertCircle,   className: 'text-red-600 bg-red-100',       border: 'border-red-200' },
};

export function ActionCenter() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const { data: alerts = [], isLoading } = useQuery({
    queryKey: ['admin-alerts-pending'],
    queryFn: () => listPendingAlerts(10),
    refetchInterval: 60_000,
  });

  const dismissMutation = useMutation({
    mutationFn: (id: string) => dismissAlert(id),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['admin-alerts-pending'] }),
    onError: () => toast.error('Erro ao dispensar alerta.'),
  });

  const handleAction = (alert: AdminAlert) => {
    const meta = alert.action_metadata as Record<string, string> | null;
    switch (alert.action_type) {
      case 'navigate':
        if (meta?.route) navigate(meta.route);
        break;
      case 'activate_opportunities':
      case 'deactivate_opportunities':
        navigate('/partner-opportunities');
        break;
      default:
        toast.info(alert.action_label || 'Acao nao configurada');
    }
  };

  if (isLoading) return null;
  if (alerts.length === 0) return null;

  return (
    <section className="space-y-3">
      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider">Action Center</h3>
      <div className="space-y-2">
        {alerts.map((alert) => {
          const config = SEVERITY_CONFIG[alert.severity];
          const Icon = config.icon;
          return (
            <div
              key={alert.id}
              className={`flex items-start gap-3 rounded-xl border p-4 bg-white ${config.border}`}
            >
              <div className={`rounded-lg p-2 ${config.className}`}>
                <Icon className="h-4 w-4" />
              </div>
              <div className="flex-1 min-w-0">
                <p className="text-sm font-semibold text-gray-800">{alert.title}</p>
                {alert.description && (
                  <p className="text-xs text-gray-500 mt-0.5">{alert.description}</p>
                )}
              </div>
              <div className="flex items-center gap-2 shrink-0">
                {alert.action_label && (
                  <button
                    onClick={() => handleAction(alert)}
                    className="px-3 py-1.5 text-xs font-semibold text-blue-700 bg-blue-100 rounded-full hover:bg-blue-200 transition-colors"
                  >
                    {alert.action_label}
                  </button>
                )}
                <button
                  onClick={() => dismissMutation.mutate(alert.id)}
                  disabled={dismissMutation.isPending}
                  className="p-1 text-gray-400 hover:text-gray-600 rounded transition-colors disabled:opacity-50"
                  title="Dispensar"
                >
                  <X className="h-4 w-4" />
                </button>
              </div>
            </div>
          );
        })}
      </div>
    </section>
  );
}
