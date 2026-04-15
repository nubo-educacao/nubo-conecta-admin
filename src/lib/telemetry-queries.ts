import { supabase } from "@/integrations/supabase/client";

// ─── Tipos para Telemetria ──────────────────────────────────────────────────

export interface AgentTurnRow {
  id: string;
  user_id: string;
  session_id: string;
  planning_latency_ms: number | null;
  reasoning_latency_ms: number | null;
  response_latency_ms: number | null;
  total_latency_ms: number | null;
  input_tokens: number | null;
  output_tokens: number | null;
  tools_used: Array<{ name: string; args: Record<string, unknown> }> | null;
  intent_category: string | null;
  reasoning_report: string | null;
  action: string | null;
  planning_output: string | null;
  reasoning_output: string | null;
  response_output: string | null;
  estimated_cost_usd: number | null;
  created_at: string;
}

export interface TelemetryKPIs {
  avgLatencyMs: number;
  turnsLast24h: number;
  totalTokens: number;
  totalToolCalls: number;
}

export interface LatencyByHour {
  hour: string; // "HH:00"
  planning: number;
  reasoning: number;
  response: number;
}

export interface TokensByDay {
  day: string; // "Seg", "Ter", etc.
  input: number;
  output: number;
}

export interface ToolStats {
  tool: string;
  calls: number;
  avgLatencyMs: number;
  successRate: number;
}

// ─── Queries ─────────────────────────────────────────────────────────────────

// 1. KPIs das últimas 24h
export async function fetchTelemetryKPIs(): Promise<TelemetryKPIs> {
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

  const { data, error } = await supabase
    .from("agent_turns")
    .select("total_latency_ms, input_tokens, output_tokens, tools_used")
    .gte("created_at", since);

  if (error) throw error;
  const rows = data ?? [];

  const avgLatency =
    rows.length > 0
      ? Math.round(rows.reduce((s, r) => s + (r.total_latency_ms ?? 0), 0) / rows.length)
      : 0;

  const totalTokens = rows.reduce(
    (s, r) => s + (r.input_tokens ?? 0) + (r.output_tokens ?? 0),
    0
  );

  const totalToolCalls = rows.reduce((s, r) => {
    const tools = r.tools_used as Array<unknown> | null;
    return s + (tools?.length ?? 0);
  }, 0);

  return {
    avgLatencyMs: avgLatency,
    turnsLast24h: rows.length,
    totalTokens,
    totalToolCalls,
  };
}

// 2. Série temporal de latência por hora (últimas 24h)
export async function fetchLatencyByHour(): Promise<LatencyByHour[]> {
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

  const { data, error } = await supabase
    .from("agent_turns")
    .select("created_at, planning_latency_ms, reasoning_latency_ms, response_latency_ms")
    .gte("created_at", since)
    .order("created_at", { ascending: true });

  if (error) throw error;

  // Agrupar por hora
  const buckets: Record<string, { planning: number[]; reasoning: number[]; response: number[] }> =
    {};
  for (const row of data ?? []) {
    const hour = new Date(row.created_at)
      .toLocaleString("pt-BR", { hour: "2-digit", minute: "2-digit" })
      .replace(/:\d{2}$/, ":00");
    if (!buckets[hour]) buckets[hour] = { planning: [], reasoning: [], response: [] };
    if (row.planning_latency_ms != null) buckets[hour].planning.push(row.planning_latency_ms);
    if (row.reasoning_latency_ms != null) buckets[hour].reasoning.push(row.reasoning_latency_ms);
    if (row.response_latency_ms != null) buckets[hour].response.push(row.response_latency_ms);
  }

  return Object.entries(buckets).map(([hour, vals]) => ({
    hour,
    planning: avg(vals.planning),
    reasoning: avg(vals.reasoning),
    response: avg(vals.response),
  }));
}

// 3. Tokens por dia (últimos 7 dias)
export async function fetchTokensByDay(): Promise<TokensByDay[]> {
  const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const dayNames = ["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sab"];

  const { data, error } = await supabase
    .from("agent_turns")
    .select("created_at, input_tokens, output_tokens")
    .gte("created_at", since)
    .order("created_at", { ascending: true });

  if (error) throw error;

  const buckets: Record<string, { input: number; output: number }> = {};
  for (const row of data ?? []) {
    const dayIdx = new Date(row.created_at).getDay();
    const dayName = dayNames[dayIdx];
    if (!buckets[dayName]) buckets[dayName] = { input: 0, output: 0 };
    buckets[dayName].input += row.input_tokens ?? 0;
    buckets[dayName].output += row.output_tokens ?? 0;
  }

  return Object.entries(buckets).map(([day, vals]) => ({ day, ...vals }));
}

// 4. Lista paginada de sessões com todos os campos
export async function fetchTurnsList(page = 0, pageSize = 20): Promise<AgentTurnRow[]> {
  const { data, error } = await supabase
    .from("agent_turns")
    .select("*")
    .order("created_at", { ascending: false })
    .range(page * pageSize, (page + 1) * pageSize - 1);

  if (error) throw error;
  return (data ?? []) as AgentTurnRow[];
}

// 5. Estatísticas de tools (derivadas de tools_used JSONB)
export async function fetchToolStats(): Promise<ToolStats[]> {
  const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();

  const { data, error } = await supabase
    .from("agent_turns")
    .select("tools_used, reasoning_latency_ms")
    .gte("created_at", since)
    .not("tools_used", "is", null);

  if (error) throw error;

  const toolMap: Record<string, { calls: number; latencies: number[] }> = {};
  for (const row of data ?? []) {
    const tools = row.tools_used as Array<{ name: string }> | null;
    if (!tools) continue;
    for (const t of tools) {
      if (!toolMap[t.name]) toolMap[t.name] = { calls: 0, latencies: [] };
      toolMap[t.name].calls += 1;
      if (row.reasoning_latency_ms != null) {
        // Aproximação: distribui latência total do reasoning igualmente entre tools
        toolMap[t.name].latencies.push(row.reasoning_latency_ms / tools.length);
      }
    }
  }

  // TODO: calcular successRate cruzando com agent_errors (futura melhoria)
  return Object.entries(toolMap)
    .map(([tool, stats]) => ({
      tool,
      calls: stats.calls,
      avgLatencyMs: avg(stats.latencies),
      successRate: 99.0, // placeholder até cruzar com agent_errors
    }))
    .sort((a, b) => b.calls - a.calls);
}

// ─── Helper ──────────────────────────────────────────────────────────────────

function avg(arr: number[]): number {
  if (arr.length === 0) return 0;
  return Math.round(arr.reduce((a, b) => a + b, 0) / arr.length);
}
