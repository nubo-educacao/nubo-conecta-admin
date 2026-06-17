import { supabase } from "@/integrations/supabase/client";

export interface PartnerFunnelData {
  partner_id: string;
  partner_name: string;
  total_unique_clicks: number;
  total_applications_started: number;
  total_applications_submitted: number;
  total_external_redirect_clicks: number;
}

export interface PartnerApplicationBucketsData {
  partner_id: string;
  completion_bucket: string;
  applications_count: number;
}

export interface FunnelUserData {
  whatsapp: string;
  full_name: string;
  funnel_phase: string;
  step_order: number;
  furthest_passport_phase: string;
  active_partner_name: string;
  progress_percent: number;
  progress_filled: number;
  progress_total: number;
  is_dependent: boolean;
  parent_full_name: string;
  external_redirect_clicks: number;
}

export async function getAdminFunnelUsers(): Promise<FunnelUserData[]> {
  const { data, error } = await supabase.rpc('get_admin_funnel_users' as any);
  if (error) throw error;
  return data as FunnelUserData[];
}

export async function getPartnerFunnel(): Promise<PartnerFunnelData[]> {
  const { data, error } = await (supabase as any)
    .from('vw_partner_funnel')
    .select('*')
    .order('total_applications_submitted', { ascending: false });
  if (error) throw error;
  return data as PartnerFunnelData[];
}

export async function getPartnerApplicationBuckets(partnerId?: string): Promise<PartnerApplicationBucketsData[]> {
  let query = (supabase as any)
    .from('vw_partner_application_completion_buckets')
    .select('*')
    .order('completion_bucket', { ascending: true });
    
  if (partnerId) {
    query = query.eq('partner_id', partnerId);
  }

  const { data, error } = await query;
  if (error) throw error;
  return data as PartnerApplicationBucketsData[];
}

export interface ApplicationsOverTimeData {
  date: string;
  label: string;
  Geral: number;
  [partnerName: string]: string | number;
}

export async function getStudentApplicationsOverTime(partnerId?: string, daysAgo?: number | null): Promise<ApplicationsOverTimeData[]> {
  const { data, error } = await supabase.rpc('get_admin_applications_over_time' as any, {
    p_partner_id: partnerId === 'all' ? null : partnerId,
    p_days_ago: daysAgo
  });

  if (error) throw error;
  
  // The RPC returns { date: 'YYYY-MM-DD', partner_name, count: number }
  const grouped = ((data as any[]) || []).reduce((acc: any, item: any) => {
    if (!acc[item.date]) {
      const [y, m, d] = item.date.split('-');
      acc[item.date] = {
        date: item.date,
        label: `${d}/${m}`,
        Geral: 0
      };
    }
    
    const count = Number(item.count);
    acc[item.date].Geral += count;
    
    if (item.partner_name) {
      acc[item.date][item.partner_name] = (acc[item.date][item.partner_name] || 0) + count;
    }
    
    return acc;
  }, {});

  const sorted = Object.keys(grouped).sort().map(k => grouped[k]);
  return sorted;
}
