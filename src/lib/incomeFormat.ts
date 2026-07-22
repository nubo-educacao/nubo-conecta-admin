// Shared income-calculator parsing/formatting (ADR-0015).
// Consumed by both the applications export helper and ApplicationAnswersModal,
// so the "Nº de Residentes / Renda Total / Renda Per Capita" breakdown never
// has to be re-implemented (and re-broken) in more than one place.

export interface IncomeBreakdown {
    residentes: number | null;
    rendaTotal: number | null;
    rendaPerCapita: number | null;
}

interface RawIncomeValue {
    family_count?: number | null;
    social_benefits?: number | null;
    alimony?: number | null;
    member_incomes?: number[] | null;
    per_capita_income?: number | null;
}

/**
 * Parses the value produced by IncomeCalculatorField. It is stored as a JSON
 * STRING in `answers` (not a nested object) — see
 * nubo-conecta-app/src/components/forms/ui-components/IncomeCalculatorField.tsx:90
 * (`onChange(JSON.stringify(fullValue))`). Defensive to both shapes (string
 * or an already-parsed object), returning null when the value isn't an
 * income-calculator payload at all.
 */
export function parseIncomeValue(value: unknown): RawIncomeValue | null {
    if (value == null) return null;

    if (typeof value === "object") {
        return "per_capita_income" in (value as object) ? (value as RawIncomeValue) : null;
    }

    if (typeof value === "string") {
        try {
            const parsed = JSON.parse(value);
            if (parsed && typeof parsed === "object" && "per_capita_income" in parsed) {
                return parsed as RawIncomeValue;
            }
        } catch {
            return null;
        }
    }

    return null;
}

/**
 * Formats a parsed income value into the 3 fields decided for both the
 * exported spreadsheet and the Respostas modal (ADR-0015): Nº de Residentes,
 * Renda Total (soma de member_incomes + social_benefits + alimony — pensão e
 * benefícios entram na soma, não viram coluna própria) e Renda Per Capita.
 */
export function formatIncomeBreakdown(raw: RawIncomeValue): IncomeBreakdown {
    const memberSum = Array.isArray(raw.member_incomes)
        ? raw.member_incomes.reduce((acc, n) => acc + (Number(n) || 0), 0)
        : 0;
    const rendaTotal = memberSum + (Number(raw.social_benefits) || 0) + (Number(raw.alimony) || 0);

    return {
        residentes: typeof raw.family_count === "number" ? raw.family_count : null,
        rendaTotal,
        rendaPerCapita: typeof raw.per_capita_income === "number" ? raw.per_capita_income : null,
    };
}

const currencyFormatter = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });

export function formatCurrencyBRL(value: number | null): string {
    if (value == null) return "—";
    return currencyFormatter.format(value);
}
