import { supabase } from '@/integrations/supabase/client';
import type { DateRange } from '@/lib/analytics-queries';
export interface OpportunityInterest {
  opportunity_id: string;
  title: string;
  provider: string;
  clicks: number;
}
export async function fetchOpportunityInterest(dateRange?: DateRange): Promise<OpportunityInterest[]> {
  // Generated database types are refreshed after this migration is applied.
  const { data, error } = await (supabase.rpc as unknown as (
    name: string, args: Record<string, unknown>,
  ) => Promise<{ data: OpportunityInterest[] | null; error: unknown }>)('get_command_center_opportunity_interest', {
    p_from: dateRange?.from?.toISOString() ?? null,
    p_to: dateRange?.to?.toISOString() ?? null,
    p_limit: 10,
  });
  if (error) throw error;
  return data ?? [];
}
