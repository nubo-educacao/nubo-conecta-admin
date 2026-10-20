import { supabase } from "@/integrations/supabase/client";
import {
  attributionRpcArgs,
  type AttributionFilter,
} from "@/lib/attributionFilter";
import type {
  AnalyticsRange,
  GlobalFunnel,
  NsmMetrics,
  L1Metrics,
  L2Metrics,
} from "@/types/productAnalytics";
export const analyticsRangeArgs = (range?: AnalyticsRange) => ({
  p_from: range?.from?.toISOString() ?? null,
  p_to: range?.to?.toISOString() ?? null,
});
async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(name as never, args as never);
  if (error) throw error;
  if (data === null) throw new Error("Contrato de analytics sem resposta");
  return data as unknown as T;
}
const filterArgs = (
  range?: AnalyticsRange,
  attribution: AttributionFilter = {},
) => ({ ...analyticsRangeArgs(range), ...attributionRpcArgs(attribution) });
export const fetchGlobalFunnel = (
  range?: AnalyticsRange,
  attribution?: AttributionFilter,
) =>
  rpc<GlobalFunnel>(
    "get_product_global_funnel",
    filterArgs(range, attribution),
  );
export const fetchL1 = (
  range?: AnalyticsRange,
  attribution?: AttributionFilter,
) => rpc<L1Metrics>("get_product_l1_metrics", filterArgs(range, attribution));
export const fetchL2 = (
  range?: AnalyticsRange,
  attribution?: AttributionFilter,
) => rpc<L2Metrics>("get_product_l2_metrics", filterArgs(range, attribution));
export const fetchNsm = (
  semester?: string,
  compare?: string,
  attribution: AttributionFilter = {},
) =>
  rpc<NsmMetrics>("get_command_center_nsm", {
    p_semester: semester ?? null,
    p_compare: compare ?? null,
    ...attributionRpcArgs(attribution),
  });
export const productAnalyticsKeys = {
  global: (range?: AnalyticsRange, attribution?: AttributionFilter) =>
    ["product-analytics", "global", filterArgs(range, attribution)] as const,
  l1: (range?: AnalyticsRange, attribution?: AttributionFilter) =>
    ["product-analytics", "l1", filterArgs(range, attribution)] as const,
  l2: (range?: AnalyticsRange, attribution?: AttributionFilter) =>
    ["product-analytics", "l2", filterArgs(range, attribution)] as const,
  nsm: (
    semester?: string,
    compare?: string,
    attribution: AttributionFilter = {},
  ) =>
    [
      "product-analytics",
      "nsm",
      semester ?? null,
      compare ?? null,
      attributionRpcArgs(attribution),
    ] as const,
};
