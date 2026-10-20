import { describe, expect, it } from "vitest";
import { formatBrt, funnelPeriodLabel, resolveFunnelPeriod } from "@/components/b2b/funnelPeriod";

const now = new Date("2026-10-20T15:00:00Z"); // 12:00 BRT

describe("B2B funnel period", () => {
  it("all-time leaves both limits open so the RPC receives NULL/NULL", () => {
    expect(resolveFunnelPeriod({ preset: "all" }, now)).toEqual({});
    expect(funnelPeriodLabel({})).toBe("Todo o período");
  });

  it("relative presets open the start only; the server closes the window at now()", () => {
    expect(resolveFunnelPeriod({ preset: "7d" }, now)).toEqual({ from: new Date("2026-10-13T15:00:00Z") });
    expect(resolveFunnelPeriod({ preset: "90d" }, now)?.from).toEqual(new Date("2026-07-22T15:00:00Z"));
  });

  it("current semester starts at BRT midnight of Jan 1 or Jul 1", () => {
    expect(resolveFunnelPeriod({ preset: "semester" }, now)).toEqual({ from: new Date("2026-07-01T03:00:00Z") });
    expect(resolveFunnelPeriod({ preset: "semester" }, new Date("2026-03-10T12:00:00Z"))).toEqual({ from: new Date("2026-01-01T03:00:00Z") });
    // 30/06 22:00 BRT is still S1 even though it is already 01/07 in UTC.
    expect(resolveFunnelPeriod({ preset: "semester" }, new Date("2026-07-01T01:00:00Z"))).toEqual({ from: new Date("2026-01-01T03:00:00Z") });
  });

  it("custom days are whole BRT days with an exclusive end", () => {
    expect(resolveFunnelPeriod({ preset: "custom", customFrom: "2026-03-01", customTo: "2026-04-30" }, now)).toEqual({
      from: new Date("2026-03-01T03:00:00Z"), to: new Date("2026-05-01T03:00:00Z"),
    });
    expect(resolveFunnelPeriod({ preset: "custom", customFrom: "2026-03-01" }, now)).toEqual({ from: new Date("2026-03-01T03:00:00Z") });
    expect(resolveFunnelPeriod({ preset: "custom", customFrom: "2026-05-02", customTo: "2026-05-01" }, now)).toBeNull();
  });

  it("labels the effective half-open window in Brasília time", () => {
    const label = funnelPeriodLabel({ from: new Date("2026-03-01T03:00:00Z"), to: new Date("2026-05-01T03:00:00Z") });
    expect(label).toContain("01/03/2026 00:00");
    expect(label).toContain("01/05/2026 00:00");
    expect(label).toMatch(/fim exclusivo/);
    expect(funnelPeriodLabel({ from: new Date("2026-07-01T03:00:00Z") })).toMatch(/até agora/);
    expect(formatBrt("2026-03-15T02:30:00Z")).toBe("14/03/2026 23:30");
  });
});
