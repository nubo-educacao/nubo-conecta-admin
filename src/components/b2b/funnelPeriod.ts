import type { AnalyticsRange } from "@/types/productAnalytics";

/** Funnel-only period (TP-G 90a). Brasília has no DST since 2019, so BRT is a fixed UTC-3. */
export type FunnelPeriodPreset = "7d" | "30d" | "90d" | "semester" | "all" | "custom";
export interface FunnelPeriod {
  preset: FunnelPeriodPreset;
  /** YYYY-MM-DD, BRT calendar days; customTo is inclusive in the UI and exclusive on the wire. */
  customFrom?: string;
  customTo?: string;
}

export const FUNNEL_PERIOD_OPTIONS: { value: FunnelPeriodPreset; label: string }[] = [
  { value: "7d", label: "Últimos 7 dias" },
  { value: "30d", label: "Últimos 30 dias" },
  { value: "90d", label: "Últimos 90 dias" },
  { value: "semester", label: "Semestre atual" },
  { value: "all", label: "Todo o período" },
  { value: "custom", label: "Personalizado" },
];

const DAY_MS = 86_400_000;
const BRT_OFFSET_MS = 3 * 3_600_000;
const brtDayStart = (isoDate: string) => new Date(isoDate + "T00:00:00-03:00");

/** Returns the half-open [from, to) window, with open limits left undefined; null for an empty custom range. */
export function resolveFunnelPeriod(period: FunnelPeriod, now = new Date()): AnalyticsRange | null {
  switch (period.preset) {
    case "all":
      return {};
    case "7d":
    case "30d":
    case "90d":
      return { from: new Date(now.getTime() - parseInt(period.preset, 10) * DAY_MS) };
    case "semester": {
      const brt = new Date(now.getTime() - BRT_OFFSET_MS);
      const startMonth = brt.getUTCMonth() < 6 ? 0 : 6;
      return { from: new Date(Date.UTC(brt.getUTCFullYear(), startMonth, 1) + BRT_OFFSET_MS) };
    }
    case "custom": {
      const range: AnalyticsRange = {};
      if (period.customFrom) range.from = brtDayStart(period.customFrom);
      if (period.customTo) range.to = new Date(brtDayStart(period.customTo).getTime() + DAY_MS);
      if (range.from && range.to && range.from >= range.to) return null;
      return range;
    }
  }
}

export function formatBrt(value: Date | string): string {
  return new Date(value)
    .toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" })
    .replace(",", "");
}

export function funnelPeriodLabel(range: AnalyticsRange): string {
  if (!range.from && !range.to) return "Todo o período";
  const from = range.from ? formatBrt(range.from) : "o início";
  const to = range.to ? formatBrt(range.to) + " (fim exclusivo)" : "agora";
  return `${from} até ${to}, horário de Brasília`;
}
