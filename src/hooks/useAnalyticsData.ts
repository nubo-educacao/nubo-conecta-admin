import { useQuery } from "@tanstack/react-query";
import {
  fetchDashboardStats,
  fetchActivityData,
  fetchTopCourses,
  fetchCommandCenterDemographics,
  fetchUserPreferences,
  fetchErrorLogs,
  fetchTopUsers,
  fetchLocationData,
  type DateRange,
  type ErrorLog,
} from "@/lib/analytics-queries";
import type { AttributionFilter } from "@/lib/attributionFilter";
import { attributionArg, attributionQueryKey } from "@/lib/commandCenterAttribution";

// Recorte por campanha/divulgador (first-touch, TP-7): `attribution` entra na
// query key de todo hook do Command Center e só é repassado ao fetcher quando
// ativo — sem filtro, a chamada é a mesma de antes.

export function useDashboardStats(dateRange?: DateRange, attribution?: AttributionFilter) {
  return useQuery({
    queryKey: ["dashboard-stats", dateRange, attributionQueryKey(attribution)],
    queryFn: () => fetchDashboardStats(dateRange, ...attributionArg(attribution)),
    staleTime: 1000 * 60 * 5,
    refetchInterval: 1000 * 60 * 5,
  });
}

export function useActivityData(dateRange?: DateRange, attribution?: AttributionFilter) {
  return useQuery({
    queryKey: ["activity-data", dateRange, attributionQueryKey(attribution)],
    queryFn: () => fetchActivityData(dateRange, ...attributionArg(attribution)),
    staleTime: 1000 * 60 * 10,
  });
}

export function useTopCourses(attribution?: AttributionFilter) {
  return useQuery({
    queryKey: ["top-courses", attributionQueryKey(attribution)],
    queryFn: () => fetchTopCourses(...attributionArg(attribution)),
    staleTime: 1000 * 60 * 30,
  });
}

/**
 * Saúde do match + demografia num único round-trip (TP-1 1B).
 * Substituiu useFunnelData: o funil linear saiu do Command Center por decisão
 * da ADR-0027 — funis viraram por domínio (MEC e parceiro), em telas próprias.
 */
export function useCommandCenterDemographics(attribution?: AttributionFilter) {
  return useQuery({
    queryKey: ["command-center-demographics", attributionQueryKey(attribution)],
    queryFn: () => fetchCommandCenterDemographics(...attributionArg(attribution)),
    staleTime: 1000 * 60 * 10,
  });
}

export function useUserPreferences(attribution?: AttributionFilter) {
  return useQuery({
    queryKey: ["user-preferences", attributionQueryKey(attribution)],
    queryFn: () => fetchUserPreferences(...attributionArg(attribution)),
    staleTime: 1000 * 60 * 30,
  });
}

export function useErrorLogs() {
  return useQuery<ErrorLog[]>({
    queryKey: ["error-logs"],
    queryFn: () => fetchErrorLogs(),
    staleTime: 1000 * 60 * 2,
    refetchInterval: 1000 * 60 * 2,
  });
}

export function useTopUsers(dateRange?: DateRange, attribution?: AttributionFilter) {
  return useQuery({
    queryKey: ["top-users", dateRange, attributionQueryKey(attribution)],
    queryFn: () => fetchTopUsers(dateRange, ...attributionArg(attribution)),
    staleTime: 1000 * 60 * 15,
  });
}

export function useLocationData(attribution?: AttributionFilter) {
  return useQuery({
    queryKey: ["location-data", attributionQueryKey(attribution)],
    queryFn: () => fetchLocationData(...attributionArg(attribution)),
    staleTime: 1000 * 60 * 30,
  });
}
