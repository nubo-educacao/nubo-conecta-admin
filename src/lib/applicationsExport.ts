// Single shared export builder for candidaturas (ADR-0015), consumed by both
// PartnerApplications.tsx (admin) and PartnerDashboard.tsx (partner portal).
// Headers and rows are ALWAYS derived from the identical field-keyed column
// list — never deduplicated independently — eliminating the asymmetric-dedup
// class of bug (desalinhamento perto de perguntas condicionais com o mesmo
// texto; campo dinâmico colidindo com um header fixo) that existed in the
// two divergent implementations this replaces.

import type { ApplicationWithDetails, OpportunityPhase } from "@/services/applicationsService";
import type { PartnerFormField } from "@/services/partnerPortalService";
import { calculateApplicationProgress } from "@/utils/calculateApplicationProgress";
import { parseIncomeValue, formatIncomeBreakdown, formatCurrencyBRL } from "@/lib/incomeFormat";

const STATUS_LABELS: Record<string, string> = {
    DRAFT: "Rascunho",
    SUBMITTED: "Enviado",
    redirected: "Redirecionado",
};

const INCOME_MAPPING_SOURCE = "user_income.per_capita_income";

export interface BuildApplicationsExportOptions {
    /** Only the admin export includes the Parceiro (institution) column — ADR-0014/0015. */
    showPartnerColumn: boolean;
    formFieldsMap?: Record<string, PartnerFormField[]>;
    /** When provided (non-empty), a Fase column is added. */
    phases?: OpportunityPhase[];
}

interface FieldGroup {
    step_id: string | null;
    fields: PartnerFormField[];
}

function groupFieldsByStep(formFields: PartnerFormField[]): FieldGroup[] {
    const activeFields = formFields.filter((f) => f.step_id != null);
    const groups: FieldGroup[] = [];
    const stepToIndex: Record<string, number> = {};

    activeFields.forEach((f) => {
        const sId = f.step_id || "no_step";
        if (stepToIndex[sId] === undefined) {
            stepToIndex[sId] = groups.length;
            groups.push({ step_id: f.step_id, fields: [f] });
        } else {
            groups[stepToIndex[sId]].fields.push(f);
        }
    });

    return groups;
}

function getFieldValue(ans: Record<string, unknown>, f: PartnerFormField): unknown {
    return ans[f.field_name] ?? (f.question_text ? ans[f.question_text] : undefined);
}

function sanitize(val: unknown): string {
    if (val == null || val === "") return "—";
    if (typeof val === "object") return JSON.stringify(val).replace(/\r?\n|\r/g, " | ");
    return String(val).replace(/\r?\n|\r/g, " | ");
}

function getEligibilityStr(app: ApplicationWithDetails): string {
    if (!app.eligibility_results || !Array.isArray(app.eligibility_results) || app.eligibility_results.length === 0) {
        return "—";
    }
    const isGrouped = app.eligibility_results.length > 0 && "partner_id" in app.eligibility_results[0];
    if (isGrouped) {
        const resultForPartner = app.eligibility_results.find((r: any) => r.partner_id === app.partner_id);
        if (!resultForPartner || resultForPartner.total_criteria == null) return "—";
        return `${resultForPartner.met_criteria || 0}/${resultForPartner.total_criteria}`;
    }
    const total = app.eligibility_results.length;
    const met = app.eligibility_results.filter((r: any) => r.met === true).length;
    return `${met}/${total}`;
}

function getProgressStr(app: ApplicationWithDetails, formFieldsMap?: Record<string, PartnerFormField[]>): string {
    if (!formFieldsMap) return "—";
    const fields = formFieldsMap[app.partner_id] || [];
    const ans = app.answers || {};
    const filled = Object.keys(ans).length;
    if (app.status === "SUBMITTED" || app.status?.toUpperCase() === "REDIRECTED") return `100% (${filled}/${filled})`;
    if (fields.length === 0) return "—";
    const percent = calculateApplicationProgress(ans, fields);
    return `${percent}% (${filled}/${fields.length})`;
}

function getPhaseStr(app: ApplicationWithDetails, phases?: OpportunityPhase[]): string {
    if (!phases || phases.length === 0) return "—";
    return phases.find((p) => p.id === app.phase_id)?.name || "Sem Fase";
}

interface DynamicColumn {
    field: PartnerFormField;
    iteration: number | null;
    isIncome: boolean;
}

/**
 * Builds a symmetric header/row export of candidaturas. Returns headers and
 * rows built from the exact same dynamicColumns list, so their lengths can
 * never drift apart.
 */
export function buildApplicationsExport(
    applications: ApplicationWithDetails[],
    formFields: PartnerFormField[],
    options: BuildApplicationsExportOptions
): { headers: string[]; rows: string[][] } {
    const fieldGroups = groupFieldsByStep(formFields);

    // Max iterations per repeatable step, across all applications.
    const stepMaxIterations: Record<string, number> = {};
    applications.forEach((app) => {
        const ans = (app.answers as Record<string, unknown>) || {};
        fieldGroups.forEach((group) => {
            if (!group.step_id) return;
            const val = ans[group.step_id];
            if (Array.isArray(val)) {
                stepMaxIterations[group.step_id] = Math.max(stepMaxIterations[group.step_id] || 0, val.length);
            }
        });
    });

    const dynamicColumns: DynamicColumn[] = [];
    fieldGroups.forEach((group) => {
        const maxIters = group.step_id ? stepMaxIterations[group.step_id] : undefined;
        if (group.step_id && maxIters) {
            for (let i = 0; i < maxIters; i++) {
                group.fields.forEach((f) => {
                    dynamicColumns.push({ field: f, iteration: i, isIncome: f.mapping_source === INCOME_MAPPING_SOURCE });
                });
            }
        } else {
            group.fields.forEach((f) => {
                dynamicColumns.push({ field: f, iteration: null, isIncome: f.mapping_source === INCOME_MAPPING_SOURCE });
            });
        }
    });

    const showPhaseColumn = !!options.phases && options.phases.length > 0;

    const fixedHeaders = [
        "Nome",
        "Whatsapp",
        ...(options.showPartnerColumn ? ["Parceiro"] : []),
        "Oportunidade",
        ...(showPhaseColumn ? ["Fase"] : []),
        "Status",
        "Elegibilidade",
        "Progresso",
        "Data",
    ];

    const dynamicHeaders: string[] = [];
    dynamicColumns.forEach((col) => {
        const baseLabel = col.field.question_text || col.field.field_name;
        const suffix = col.iteration != null ? ` (${col.iteration + 1})` : "";
        if (col.isIncome) {
            dynamicHeaders.push(`Nº de Residentes${suffix}`, `Renda Total${suffix}`, `Renda Per Capita${suffix}`);
        } else {
            dynamicHeaders.push(`${baseLabel}${suffix}`);
        }
    });

    const headers = [...fixedHeaders, ...dynamicHeaders];

    const rows = applications.map((app) => {
        const fixedCols = [
            app.full_name || "—",
            app.phone || "—",
            ...(options.showPartnerColumn ? [app.institution_name || "—"] : []),
            app.partner_name || "—",
            ...(showPhaseColumn ? [getPhaseStr(app, options.phases)] : []),
            STATUS_LABELS[app.status] || app.status,
            getEligibilityStr(app),
            getProgressStr(app, options.formFieldsMap),
            new Date(app.created_at).toLocaleDateString("pt-BR"),
        ];

        const ans = (app.answers as Record<string, unknown>) || {};
        const dynamicCols: string[] = [];

        dynamicColumns.forEach((col) => {
            let rawValue: unknown;
            if (col.field.step_id && col.iteration != null) {
                const stepArr = (ans[col.field.step_id] as any[]) || [];
                const iterData = stepArr[col.iteration] || {};
                rawValue = getFieldValue(iterData, col.field);
            } else {
                rawValue = getFieldValue(ans, col.field);
            }

            if (col.isIncome) {
                const parsed = parseIncomeValue(rawValue);
                if (parsed) {
                    const breakdown = formatIncomeBreakdown(parsed);
                    dynamicCols.push(
                        breakdown.residentes != null ? String(breakdown.residentes) : "—",
                        formatCurrencyBRL(breakdown.rendaTotal),
                        formatCurrencyBRL(breakdown.rendaPerCapita)
                    );
                } else {
                    dynamicCols.push("—", "—", "—");
                }
            } else {
                dynamicCols.push(sanitize(rawValue));
            }
        });

        return [...fixedCols, ...dynamicCols];
    });

    return { headers, rows };
}

/** Serializes headers/rows to CSV (BOM + `;`-delimited, matching the sheets already in use) and triggers a browser download. */
export function downloadApplicationsCsv(headers: string[], rows: string[][], filename: string) {
    const formatCell = (val: string) => `"${val.replace(/"/g, '""')}"`;
    const BOM = String.fromCharCode(0xfeff);
    const csvContent =
        BOM + [headers.map(formatCell).join(";"), ...rows.map((r) => r.map(formatCell).join(";"))].join("\n");

    const blob = new Blob([csvContent], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    link.click();
    URL.revokeObjectURL(url);
}
