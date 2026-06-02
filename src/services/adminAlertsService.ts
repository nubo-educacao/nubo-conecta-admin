import { supabase } from '@/integrations/supabase/client';

export type AlertSeverity = 'info' | 'warning' | 'critical';
export type AlertStatus = 'pending' | 'acknowledged' | 'resolved' | 'dismissed';

export interface AdminAlert {
  id: string;
  alert_type: string;
  severity: AlertSeverity;
  title: string;
  description: string | null;
  entity_type: string | null;
  entity_id: string | null;
  action_label: string | null;
  action_type: string | null;
  action_metadata: Record<string, unknown>;
  status: AlertStatus;
  resolved_by: string | null;
  resolved_at: string | null;
  created_at: string;
  expires_at: string | null;
}

export async function listPendingAlerts(limit = 10): Promise<AdminAlert[]> {
  const { data, error } = await supabase
    .from('admin_alerts')
    .select('*')
    .eq('status', 'pending')
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) throw new Error(`listPendingAlerts failed: ${error.message}`);
  return (data ?? []) as AdminAlert[];
}

export async function resolveAlert(id: string, resolvedBy: string): Promise<void> {
  const { error } = await supabase
    .from('admin_alerts')
    .update({ status: 'resolved', resolved_by: resolvedBy, resolved_at: new Date().toISOString() })
    .eq('id', id);

  if (error) throw new Error(`resolveAlert failed: ${error.message}`);
}

export async function dismissAlert(id: string): Promise<void> {
  const { error } = await supabase
    .from('admin_alerts')
    .update({ status: 'dismissed' })
    .eq('id', id);

  if (error) throw new Error(`dismissAlert failed: ${error.message}`);
}

export async function countPendingAlerts(): Promise<number> {
  const { count, error } = await supabase
    .from('admin_alerts')
    .select('*', { count: 'exact', head: true })
    .eq('status', 'pending');

  if (error) throw new Error(`countPendingAlerts failed: ${error.message}`);
  return count ?? 0;
}
