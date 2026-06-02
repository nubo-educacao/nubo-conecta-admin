import { useQuery } from "@tanstack/react-query";
import {
  fetchTelemetryKPIs,
  fetchLatencyByHour,
  fetchTokensByDay,
  fetchTurnsList,
  fetchToolStats,
  type TelemetryKPIs,
  type LatencyByHour,
  type TokensByDay,
  type AgentTurnRow,
  type ToolStats,
} from "@/lib/telemetry-queries";

export function useTelemetryKPIs() {
  return useQuery<TelemetryKPIs>({
    queryKey: ["telemetry-kpis"],
    queryFn: fetchTelemetryKPIs,
    staleTime: 1000 * 60 * 2,
    refetchInterval: 1000 * 60 * 2,
  });
}

export function useLatencyByHour() {
  return useQuery<LatencyByHour[]>({
    queryKey: ["telemetry-latency-hour"],
    queryFn: fetchLatencyByHour,
    staleTime: 1000 * 60 * 5,
  });
}

export function useTokensByDay() {
  return useQuery<TokensByDay[]>({
    queryKey: ["telemetry-tokens-day"],
    queryFn: fetchTokensByDay,
    staleTime: 1000 * 60 * 10,
  });
}

export function useTurnsList(page = 0) {
  return useQuery<AgentTurnRow[]>({
    queryKey: ["telemetry-turns-list", page],
    queryFn: () => fetchTurnsList(page),
    staleTime: 1000 * 60 * 2,
  });
}

export function useToolStats() {
  return useQuery<ToolStats[]>({
    queryKey: ["telemetry-tool-stats"],
    queryFn: fetchToolStats,
    staleTime: 1000 * 60 * 10,
  });
}
