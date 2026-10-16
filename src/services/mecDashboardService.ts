import { supabase } from "@/integrations/supabase/client";
export interface MecMetrics {
  card_view: number; card_click: number; redirect: number;
  distinct_users: number; distinct_identities: number;
}
export interface MecEntity extends MecMetrics { entity_id: string; first_observed_at: string }
export interface MecDashboardData {
  entities: MecEntity[];
  totals: MecMetrics;
  cohort: { viewers: number; clickers: number; redirectors: number };
  coverage: { first_observed_at: string | null; first_view_at: string | null; legacy_events: number };
  period: { from: string | null; to: string };
}
export async function getMecDashboard(entityId?: string, daysAgo: number | null = 30): Promise<MecDashboardData> {
  const { data, error } = await supabase.rpc("get_mec_engagement_dashboard" as any, {
    p_entity_id: entityId || null, p_days_ago: daysAgo,
  });
  if (error) throw error;
  return data as unknown as MecDashboardData;
}
export function cohortRate(numerator: number, denominator: number): number | null {
  return denominator > 0 ? numerator / denominator * 100 : null;
}

