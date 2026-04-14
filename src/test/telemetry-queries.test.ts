import { describe, it, expect, vi, beforeEach } from "vitest";
import { fetchTelemetryKPIs } from "@/lib/telemetry-queries";
import { supabase } from "@/integrations/supabase/client";

vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    from: vi.fn(),
  },
}));

describe("fetchTelemetryKPIs", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("retorna KPIs calculados corretamente", async () => {
    vi.mocked(supabase.from).mockReturnValue({
      select: vi.fn().mockReturnValue({
        gte: vi.fn().mockResolvedValue({
          data: [
            {
              total_latency_ms: 1000,
              input_tokens: 500,
              output_tokens: 200,
              tools_used: [{ name: "search_opportunities" }],
            },
            {
              total_latency_ms: 2000,
              input_tokens: 300,
              output_tokens: 100,
              tools_used: [],
            },
          ],
          error: null,
        }),
      }),
    } as any);

    const kpis = await fetchTelemetryKPIs();

    expect(kpis.avgLatencyMs).toBe(1500);
    expect(kpis.turnsLast24h).toBe(2);
    expect(kpis.totalTokens).toBe(1100);
    expect(kpis.totalToolCalls).toBe(1);
  });

  it("retorna zeros quando não há dados", async () => {
    vi.mocked(supabase.from).mockReturnValue({
      select: vi.fn().mockReturnValue({
        gte: vi.fn().mockResolvedValue({ data: [], error: null }),
      }),
    } as any);

    const kpis = await fetchTelemetryKPIs();

    expect(kpis.avgLatencyMs).toBe(0);
    expect(kpis.turnsLast24h).toBe(0);
    expect(kpis.totalTokens).toBe(0);
    expect(kpis.totalToolCalls).toBe(0);
  });

  it("lança erro quando supabase retorna error", async () => {
    vi.mocked(supabase.from).mockReturnValue({
      select: vi.fn().mockReturnValue({
        gte: vi.fn().mockResolvedValue({ data: null, error: new Error("DB error") }),
      }),
    } as any);

    await expect(fetchTelemetryKPIs()).rejects.toThrow("DB error");
  });
});
