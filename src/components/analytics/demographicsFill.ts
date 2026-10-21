import type { DistributionSlice } from "@/lib/analytics-queries";

export const UNANSWERED = "Não respondeu";
export const QUOTA_COLOR = "hsl(var(--chart-4))";

const BAR_COLORS = [
    "hsl(var(--primary))",
    "hsl(var(--chart-2))",
    "hsl(var(--chart-3))",
    "hsl(var(--chart-4))",
    "hsl(var(--chart-5))",
];

/**
 * O bucket "Não respondeu" é cinza de propósito: é ausência de dado, não
 * categoria. Inferido por cota (NUB-RD-92) é hachurado, para nunca parecer
 * autodeclaração.
 */
export const sliceFill = (slice: DistributionSlice, index: number, quotaPatternId = "quota-inferred") => {
    if (slice.source === "quota_inferred") return `url(#${quotaPatternId})`;
    if (slice.source === "unanswered" || slice.label === UNANSWERED) return "hsl(var(--muted-foreground))";
    return BAR_COLORS[index % BAR_COLORS.length];
};
