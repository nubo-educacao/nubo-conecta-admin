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
  coverage: { first_observed_at: string | null; first_view_at: string | null; legacy_events: number; redirect: import('@/types/productAnalytics').InstrumentationCoverage };
  period: { from: string | null; to: string };
}
export async function getMecDashboard(entityId?: string, daysAgo: number | null = 30): Promise<MecDashboardData> {
  const { data, error } = await supabase.rpc("get_mec_engagement_dashboard" as any, {
    p_entity_id: entityId ? toMecEntityId(entityId) : null, p_days_ago: daysAgo,
  });
  if (error) throw error;
  return data as unknown as MecDashboardData;
}
export function cohortRate(numerator: number, denominator: number): number | null {
  return denominator > 0 ? numerator / denominator * 100 : null;
}


export interface MecVolumeOptions {
 range?: import('@/types/productAnalytics').AnalyticsRange; search?:string;institutionId?:string;type?:string;
 order?:'views'|'clicks'|'redirects'|'users';limit?:number;offset?:number;
}
export function toMecEntityId(id:string):string{return id.replace(/^mec_/,'');}
export async function getMecOpportunityVolumes(options:MecVolumeOptions={}):Promise<import('@/types/productAnalytics').MecVolumes>{
 const {data,error}=await supabase.rpc('get_mec_opportunity_volumes' as never,{
 p_from:options.range?.from?.toISOString()??null,p_to:options.range?.to?.toISOString()??null,p_search:options.search??null,
 p_institution_id:options.institutionId??null,p_type:options.type??null,p_order:options.order??'views',p_limit:options.limit??25,p_offset:options.offset??0
 } as never);if(error)throw error;if(data===null)throw new Error('Volumes MEC sem resposta');return data as unknown as import('@/types/productAnalytics').MecVolumes;
}
export async function getMecVolumeInstitutions(range?:import('@/types/productAnalytics').AnalyticsRange):Promise<{id:string;name:string}[]>{
 const {data,error}=await supabase.rpc('get_mec_volume_institutions' as never,{p_from:range?.from?.toISOString()??null,p_to:range?.to?.toISOString()??null} as never);
 if(error)throw error;return (data??[]) as unknown as {id:string;name:string}[];
}
/** Derive once and share this window with the volume query. The existing dashboard RPC uses days. */
export function mecDashboardRange(daysAgo:number|null,to=new Date()):import('@/types/productAnalytics').AnalyticsRange {
 return {from:daysAgo===null?undefined:new Date(to.getTime()-daysAgo*86400000),to};
}

/** Use the server-normalized dashboard range for a second, exactly aligned volume query. */
export function mecRangeFromDashboard(data:MecDashboardData):import('@/types/productAnalytics').AnalyticsRange{
 return {from:data.period.from?new Date(data.period.from):undefined,to:new Date(data.period.to)};
}
