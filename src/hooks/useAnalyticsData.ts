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
  fetchOpportunityTypes,
  type DateRange,
  type ErrorLog,
} from "@/lib/analytics-queries";

export function useDashboardStats(dateRange?: DateRange) {
  return useQuery({
    queryKey: ["dashboard-stats", dateRange],
    queryFn: () => fetchDashboardStats(dateRange),
    staleTime: 1000 * 60 * 5,
    refetchInterval: 1000 * 60 * 5,
  });
}

export function useActivityData() {
  return useQuery({
    queryKey: ["activity-data"],
    queryFn: fetchActivityData,
    staleTime: 1000 * 60 * 10,
  });
}

export function useTopCourses() {
  return useQuery({
    queryKey: ["top-courses"],
    queryFn: fetchTopCourses,
    staleTime: 1000 * 60 * 30,
  });
}

/**
 * Saúde do match + demografia num único round-trip (TP-1 1B).
 * Substituiu useFunnelData: o funil linear saiu do Command Center por decisão
 * da ADR-0027 — funis viraram por domínio (MEC e parceiro), em telas próprias.
 */
export function useCommandCenterDemographics() {
  return useQuery({
    queryKey: ["command-center-demographics"],
    queryFn: fetchCommandCenterDemographics,
    staleTime: 1000 * 60 * 10,
  });
}

export function useUserPreferences() {
  return useQuery({
    queryKey: ["user-preferences"],
    queryFn: fetchUserPreferences,
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

export function useTopUsers() {
  return useQuery({
    queryKey: ["top-users"],
    queryFn: fetchTopUsers,
    staleTime: 1000 * 60 * 15,
  });
}

export function useLocationData() {
  return useQuery({
    queryKey: ["location-data"],
    queryFn: fetchLocationData,
    staleTime: 1000 * 60 * 30,
  });
}

export function useOpportunityTypes() {
  return useQuery({
    queryKey: ["opportunity-types"],
    queryFn: fetchOpportunityTypes,
    staleTime: 1000 * 60 * 15,
  });
}
