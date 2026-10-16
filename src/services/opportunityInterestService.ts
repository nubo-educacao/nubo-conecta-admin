import { supabase } from '@/integrations/supabase/client';
import type { DateRange } from '@/lib/analytics-queries';
import { attributionRpcArgs, type AttributionFilter } from '@/lib/attributionFilter';
export interface OpportunityInterest {
  opportunity_id: string;
  title: string;
  provider: string;
  clicks: number;
}
export async function fetchOpportunityInterest(dateRange?: DateRange, attribution?: AttributionFilter): Promise<OpportunityInterest[]> {
  // Generated database types are refreshed after this migration is applied.
  const { data, error } = await (supabase.rpc as unknown as (
    name: string, args: Record<string, unknown>,
  ) => Promise<{ data: OpportunityInterest[] | null; error: unknown }>)('get_command_center_opportunity_interest', {
    p_from: dateRange?.from?.toISOString() ?? null,
    p_to: dateRange?.to?.toISOString() ?? null,
    p_limit: 10,
    // Recorte first-touch (campanha/divulgador): só com filtro ativo; sem ele, args de antes.
    ...attributionRpcArgs(attribution ?? {}),
  });
  if (error) throw error;
  return data ?? [];
}
