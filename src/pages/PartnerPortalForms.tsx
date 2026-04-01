import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import {
    getMyPartnerId,
    getPartnerDetails,
    getPartnerSteps,
    getPartnerFormFieldsFull,
    type PartnerStep,
    type PartnerFormFieldFull,
} from "@/services/partnerPortalService";
import { DATA_TYPES, getMappingLabel, MASK_TYPES_TEXT, MASK_TYPES_NUMBER } from "@/constants/formConstants";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Accordion, AccordionItem, AccordionTrigger, AccordionContent } from "@/components/ui/accordion";
import {
    XCircle,
    ListChecks,
    Layers,
    ShieldCheck,
    CircleDot,
    Shield,
    Database,
    ToggleRight,
} from "lucide-react";
import {
    BarChart,
    Bar,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip as RechartsTooltip,
    ResponsiveContainer,
} from "recharts";

// ─── Rule Display Helper ────────────────────────────────────────────────────

const parseRule = (jsonLogic: Record<string, unknown> | null) => {
    if (!jsonLogic || typeof jsonLogic !== "object") return null;
    const operator = Object.keys(jsonLogic)[0];
    const args = jsonLogic[operator] as unknown[];
    if (Array.isArray(args) && args.length === 2 && (args[0] as Record<string, string>)?.var) {
        return {
            field: (args[0] as Record<string, string>).var,
            operator,
            value: String(args[1]),
        };
    }
    return null;
};

const formatRuleDisplay = (rule: Record<string, unknown> | null, allFields: PartnerFormFieldFull[]) => {
    const parsed = parseRule(rule);
    if (!parsed) return null;

    let opLabel = parsed.operator;
    if (parsed.operator === "==") opLabel = "for igual a";
    if (parsed.operator === "!=") opLabel = "for diferente de";
    if (parsed.operator === "in") opLabel = "estiver em";

    if (parsed.field === "_iteration_index") {
        const val = parsed.value === "0" ? "Primeira iteração" : `Iteração ${parsed.value}`;
        return `Exibir se iteração ${opLabel} "${val}"`;
    }

    const triggerField = allFields.find((f) => f.field_name === parsed.field);
    const fieldLabel = triggerField ? triggerField.question_text : parsed.field;
    return `Exibir se [${fieldLabel}] ${opLabel} "${parsed.value}"`;
};

// ─── Question Card ──────────────────────────────────────────────────────────

function QuestionCard({
    field,
    index,
    allFields,
}: {
    field: PartnerFormFieldFull;
    index: number;
    allFields: PartnerFormFieldFull[];
}) {
    const typeLabel = DATA_TYPES.find((d) => d.value === field.data_type)?.label || field.data_type;
    const ruleDisplay = formatRuleDisplay(field.conditional_rule, allFields);
    const maskLabel =
        field.maskking && field.maskking !== "none"
            ? [...MASK_TYPES_TEXT, ...MASK_TYPES_NUMBER].find((m) => m.value === field.maskking)?.label || field.maskking
            : null;

    const hasOptions =
        field.data_type === "select" ||
        field.data_type === "multiselect" ||
        field.data_type === "searchable_select";
    const isGrid = field.data_type === "grid_select" || field.data_type === "grid_multiselect";

    return (
        <div className="rounded-lg border bg-card p-4 space-y-3">
            {/* Header */}
            <div className="flex items-start justify-between gap-2">
                <div className="flex items-start gap-3 min-w-0">
                    <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary text-xs font-bold">
                        {index + 1}
                    </span>
                    <div className="min-w-0">
                        <p className="font-medium text-sm leading-snug">{field.question_text}</p>
                        <p className="text-[11px] text-muted-foreground font-mono mt-0.5">{field.field_name}</p>
                    </div>
                </div>
                <div className="flex items-center gap-1.5 shrink-0">
                    <Badge variant="outline" className="text-[11px]">
                        {typeLabel}
                    </Badge>
                    {!field.optional && (
                        <Badge variant="default" className="bg-blue-500/80 text-[11px]">
                            Obrigatória
                        </Badge>
                    )}
                    {field.is_criterion && (
                        <Badge variant="default" className="bg-amber-500/80 text-[11px]">
                            Critério
                        </Badge>
                    )}
                </div>
            </div>

            {/* Metadata Row */}
            <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
                {field.mapping_source && (
                    <span className="flex items-center gap-1">
                        <Database className="h-3 w-3" />
                        {getMappingLabel(field.mapping_source)}
                    </span>
                )}
                {maskLabel && (
                    <span className="flex items-center gap-1">
                        <ToggleRight className="h-3 w-3" />
                        Máscara: {maskLabel}
                    </span>
                )}
            </div>

            {/* Conditional Rule */}
            {ruleDisplay && (
                <div className="text-[11px] text-orange-600 font-medium flex items-center gap-1 italic bg-orange-50 rounded px-2 py-1">
                    <Shield className="h-3 w-3 shrink-0" />
                    {ruleDisplay}
                </div>
            )}

            {/* Options */}
            {hasOptions && Array.isArray(field.options) && field.options.length > 0 && (
                <div className="space-y-1">
                    <p className="text-xs font-medium text-muted-foreground">Opções:</p>
                    <div className="flex flex-wrap gap-1">
                        {(field.options as string[]).map((opt, i) => (
                            <Badge key={i} variant="secondary" className="text-[11px] font-normal">
                                {opt}
                            </Badge>
                        ))}
                    </div>
                </div>
            )}

            {/* Grid Options */}
            {isGrid && field.options && typeof field.options === "object" && !Array.isArray(field.options) && (
                <div className="space-y-2">
                    {(field.options as Record<string, string[]>).rows?.length > 0 && (
                        <div>
                            <p className="text-xs font-medium text-muted-foreground">Linhas:</p>
                            <div className="flex flex-wrap gap-1 mt-0.5">
                                {(field.options as Record<string, string[]>).rows.map((r, i) => (
                                    <Badge key={i} variant="secondary" className="text-[11px] font-normal">{r}</Badge>
                                ))}
                            </div>
                        </div>
                    )}
                    {(field.options as Record<string, string[]>).columns?.length > 0 && (
                        <div>
                            <p className="text-xs font-medium text-muted-foreground">Colunas:</p>
                            <div className="flex flex-wrap gap-1 mt-0.5">
                                {(field.options as Record<string, string[]>).columns.map((c, i) => (
                                    <Badge key={i} variant="outline" className="text-[11px] font-normal">{c}</Badge>
                                ))}
                            </div>
                        </div>
                    )}
                </div>
            )}

            {/* Criterion Rule */}
            {field.is_criterion && field.criterion_rule && (
                <div className="text-[11px] text-amber-700 font-medium flex items-center gap-1 bg-amber-50 rounded px-2 py-1">
                    <ShieldCheck className="h-3 w-3 shrink-0" />
                    Regra de critério: {JSON.stringify(field.criterion_rule)}
                </div>
            )}
        </div>
    );
}

// ─── Main Component ─────────────────────────────────────────────────────────

export default function PartnerPortalForms() {
    // 1. Resolve partner
    const { data: partnerId, isLoading: loadingPartnerId } = useQuery({
        queryKey: ["myPartnerId"],
        queryFn: getMyPartnerId,
    });

    // 2. Partner details
    const { data: partner } = useQuery({
        queryKey: ["partnerDetails", partnerId],
        queryFn: () => getPartnerDetails(partnerId!),
        enabled: !!partnerId,
    });

    // 3. Steps
    const { data: steps = [], isLoading: loadingSteps } = useQuery({
        queryKey: ["partnerSteps", partnerId],
        queryFn: () => getPartnerSteps(partnerId!),
        enabled: !!partnerId,
    });

    // 4. Form fields
    const { data: formFields = [], isLoading: loadingFields } = useQuery({
        queryKey: ["partnerFormFieldsFull", partnerId],
        queryFn: () => getPartnerFormFieldsFull(partnerId!),
        enabled: !!partnerId,
    });

    // ─── Computed Stats ──────────────────────────────────────────────────────

    const stats = useMemo(() => {
        const totalQuestions = formFields.length;
        const totalSteps = steps.length;
        const criterionCount = formFields.filter((f) => f.is_criterion).length;
        const optionalCount = formFields.filter((f) => f.optional).length;
        return { totalQuestions, totalSteps, criterionCount, optionalCount };
    }, [formFields, steps]);

    // ─── Chart Data ──────────────────────────────────────────────────────────

    const chartData = useMemo(() => {
        return steps.map((step) => ({
            name: step.step_name,
            perguntas: formFields.filter((f) => f.step_id === step.id).length,
        }));
    }, [steps, formFields]);

    // ─── Fields Grouped by Step ──────────────────────────────────────────────

    const fieldsByStep = useMemo(() => {
        const map = new Map<string, PartnerFormFieldFull[]>();
        for (const step of steps) {
            map.set(
                step.id,
                formFields.filter((f) => f.step_id === step.id)
            );
        }
        // Fields without a step
        const orphans = formFields.filter((f) => !f.step_id);
        if (orphans.length > 0) {
            map.set("__no_step__", orphans);
        }
        return map;
    }, [steps, formFields]);

    // ─── Loading & Error States ──────────────────────────────────────────────

    if (loadingPartnerId || loadingSteps || loadingFields) {
        return (
            <div className="flex h-full items-center justify-center">
                <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
            </div>
        );
    }

    if (!partnerId) {
        return (
            <div className="flex h-full items-center justify-center">
                <Card className="max-w-md">
                    <CardContent className="pt-6 text-center">
                        <XCircle className="h-12 w-12 text-destructive mx-auto mb-4" />
                        <p className="font-medium">Acesso não autorizado</p>
                        <p className="text-sm text-muted-foreground mt-2">
                            Sua conta não está vinculada a nenhum parceiro. Contate o administrador.
                        </p>
                    </CardContent>
                </Card>
            </div>
        );
    }

    return (
        <div className="space-y-6">
            {/* Page Header */}
            <div>
                <h1 className="text-2xl font-bold tracking-tight">{partner?.name || "Portal do Parceiro"}</h1>
                <p className="text-muted-foreground">Visualize as perguntas do formulário</p>
            </div>

            {/* Stats Cards */}
            <div className="grid grid-cols-1 sm:grid-cols-4 gap-4">
                <Card>
                    <CardContent className="pt-6 flex items-center gap-4">
                        <div className="p-3 rounded-full bg-primary/10">
                            <ListChecks className="h-5 w-5 text-primary" />
                        </div>
                        <div>
                            <p className="text-2xl font-bold">{stats.totalQuestions}</p>
                            <p className="text-xs text-muted-foreground">Total de Perguntas</p>
                        </div>
                    </CardContent>
                </Card>
                <Card>
                    <CardContent className="pt-6 flex items-center gap-4">
                        <div className="p-3 rounded-full bg-violet-500/10">
                            <Layers className="h-5 w-5 text-violet-500" />
                        </div>
                        <div>
                            <p className="text-2xl font-bold">{stats.totalSteps}</p>
                            <p className="text-xs text-muted-foreground">Etapas do Formulário</p>
                        </div>
                    </CardContent>
                </Card>
                <Card>
                    <CardContent className="pt-6 flex items-center gap-4">
                        <div className="p-3 rounded-full bg-amber-500/10">
                            <ShieldCheck className="h-5 w-5 text-amber-500" />
                        </div>
                        <div>
                            <p className="text-2xl font-bold">{stats.criterionCount}</p>
                            <p className="text-xs text-muted-foreground">Perguntas com Critério</p>
                        </div>
                    </CardContent>
                </Card>
                <Card>
                    <CardContent className="pt-6 flex items-center gap-4">
                        <div className="p-3 rounded-full bg-green-500/10">
                            <CircleDot className="h-5 w-5 text-green-500" />
                        </div>
                        <div>
                            <p className="text-2xl font-bold">{stats.optionalCount}</p>
                            <p className="text-xs text-muted-foreground">Perguntas Opcionais</p>
                        </div>
                    </CardContent>
                </Card>
            </div>

            {/* Chart: Questions per Step */}
            {chartData.length > 0 && (
                <Card>
                    <CardHeader>
                        <CardTitle className="text-lg">Perguntas por Etapa</CardTitle>
                        <CardDescription>
                            Quantidade de perguntas em cada etapa do formulário.
                        </CardDescription>
                    </CardHeader>
                    <CardContent className="h-[250px] w-full">
                        <ResponsiveContainer width="100%" height="100%">
                            <BarChart data={chartData} margin={{ top: 10, right: 10, left: -20, bottom: 0 }}>
                                <CartesianGrid strokeDasharray="3 3" vertical={false} />
                                <XAxis dataKey="name" fontSize={12} />
                                <YAxis fontSize={12} allowDecimals={false} />
                                <RechartsTooltip cursor={{ fill: "transparent" }} />
                                <Bar dataKey="perguntas" fill="#8b5cf6" radius={[4, 4, 0, 0]} name="Perguntas" />
                            </BarChart>
                        </ResponsiveContainer>
                    </CardContent>
                </Card>
            )}

            {/* Questions Accordion by Step */}
            <Card>
                <CardHeader>
                    <CardTitle className="text-lg">Perguntas do Formulário</CardTitle>
                    <CardDescription>
                        {formFields.length} perguntas organizadas em {steps.length} etapa{steps.length !== 1 ? "s" : ""}
                    </CardDescription>
                </CardHeader>
                <CardContent>
                    <Accordion type="single" collapsible className="space-y-2">
                        {steps.map((step) => {
                            const stepFields = fieldsByStep.get(step.id) || [];
                            return (
                                <AccordionItem key={step.id} value={step.id} className="border rounded-lg px-4">
                                    <AccordionTrigger className="hover:no-underline py-4">
                                        <div className="flex items-center gap-3">
                                            <Badge variant="secondary" className="shrink-0">
                                                Etapa {step.sort_order}
                                            </Badge>
                                            <span className="font-medium">{step.step_name}</span>
                                            <span className="text-xs text-muted-foreground">
                                                ({stepFields.length} pergunta{stepFields.length !== 1 ? "s" : ""})
                                            </span>
                                        </div>
                                    </AccordionTrigger>
                                    <AccordionContent className="pb-4">
                                        {step.introduction && (
                                            <p className="text-sm text-muted-foreground mb-4 italic bg-muted/50 rounded p-3">
                                                {step.introduction}
                                            </p>
                                        )}
                                        <div className="space-y-3">
                                            {stepFields.map((field, i) => (
                                                <QuestionCard
                                                    key={field.id}
                                                    field={field}
                                                    index={i}
                                                    allFields={formFields}
                                                />
                                            ))}
                                            {stepFields.length === 0 && (
                                                <p className="text-sm text-muted-foreground text-center py-4">
                                                    Nenhuma pergunta nesta etapa.
                                                </p>
                                            )}
                                        </div>
                                    </AccordionContent>
                                </AccordionItem>
                            );
                        })}

                        {/* Orphan fields (no step) */}
                        {fieldsByStep.has("__no_step__") && (
                            <AccordionItem value="__no_step__" className="border rounded-lg px-4">
                                <AccordionTrigger className="hover:no-underline py-4">
                                    <div className="flex items-center gap-3">
                                        <Badge variant="outline" className="shrink-0">
                                            Sem Etapa
                                        </Badge>
                                        <span className="font-medium">Perguntas sem etapa definida</span>
                                        <span className="text-xs text-muted-foreground">
                                            ({fieldsByStep.get("__no_step__")!.length} pergunta
                                            {fieldsByStep.get("__no_step__")!.length !== 1 ? "s" : ""})
                                        </span>
                                    </div>
                                </AccordionTrigger>
                                <AccordionContent className="pb-4">
                                    <div className="space-y-3">
                                        {fieldsByStep.get("__no_step__")!.map((field, i) => (
                                            <QuestionCard
                                                key={field.id}
                                                field={field}
                                                index={i}
                                                allFields={formFields}
                                            />
                                        ))}
                                    </div>
                                </AccordionContent>
                            </AccordionItem>
                        )}
                    </Accordion>
                </CardContent>
            </Card>
        </div>
    );
}
