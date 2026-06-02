import { useState, useEffect, useCallback } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Command, CommandEmpty, CommandGroup, CommandItem, CommandList } from "@/components/ui/command";
import { Plus, Trash2, ChevronDown, X, Check, ChevronsUpDown } from "lucide-react";
import { cn } from "@/lib/utils";

// ─── Types ───────────────────────────────────────────────────────────────────

interface Condition {
    id: string;
    operator: string;
    value: string;
}

type Combinator = "and" | "or";

interface CriterionRuleBuilderProps {
    fieldName: string;
    value: string; // JSON Logic string
    onChange: (jsonLogicString: string) => void;
    dataType?: string;
    optionsList?: string[];
    label?: string;
}

// ─── Constants ───────────────────────────────────────────────────────────────

const OPERATORS = [
    { value: "==", label: "Igual a" },
    { value: "!=", label: "Diferente de" },
    { value: "<", label: "Menor que" },
    { value: "<=", label: "Menor ou igual a" },
    { value: ">", label: "Maior que" },
    { value: ">=", label: "Maior ou igual a" },
    { value: "in", label: "Está na lista" },
];

// ─── JSON Logic Helpers ──────────────────────────────────────────────────────

function generateId() {
    return Math.random().toString(36).slice(2, 9);
}

function conditionsToJsonLogic(
    conditions: Condition[],
    combinator: Combinator,
    fieldName: string
): Record<string, unknown> | null {
    if (conditions.length === 0) return null;

    const rules = conditions
        .filter((c) => c.value !== "")
        .map((c) => {
            const varRef = { var: fieldName };
            let parsedValue: unknown = c.value;

            // Try to parse as number
            const num = Number(c.value);
            if (!isNaN(num) && c.value.trim() !== "") {
                parsedValue = num;
            }

            // "in" operator: value is a comma-separated list
            if (c.operator === "in") {
                const list = c.value.split(",").map((v) => {
                    const trimmed = v.trim();
                    const n = Number(trimmed);
                    return !isNaN(n) && trimmed !== "" ? n : trimmed;
                });
                return { in: [varRef, list] };
            }

            return { [c.operator]: [varRef, parsedValue] };
        });

    if (rules.length === 0) return null;
    if (rules.length === 1) return rules[0];
    return { [combinator]: rules };
}

function jsonLogicToConditions(
    jsonLogic: Record<string, unknown> | null,
    fieldName: string
): { conditions: Condition[]; combinator: Combinator } {
    if (!jsonLogic || typeof jsonLogic !== "object") {
        return { conditions: [{ id: generateId(), operator: "==", value: "" }], combinator: "and" };
    }

    // Check if it's a combinator (AND/OR)
    if ("and" in jsonLogic && Array.isArray(jsonLogic.and)) {
        const conditions = (jsonLogic.and as Record<string, unknown>[]).map(parseCondition);
        return { conditions, combinator: "and" };
    }
    if ("or" in jsonLogic && Array.isArray(jsonLogic.or)) {
        const conditions = (jsonLogic.or as Record<string, unknown>[]).map(parseCondition);
        return { conditions, combinator: "or" };
    }

    // Single condition
    return { conditions: [parseCondition(jsonLogic)], combinator: "and" };
}

function parseCondition(rule: Record<string, unknown>): Condition {
    const id = generateId();

    for (const op of ["==", "!=", "<", "<=", ">", ">="]) {
        if (op in rule && Array.isArray(rule[op])) {
            const args = rule[op] as unknown[];
            const value = args.length > 1 ? String(args[1]) : "";
            return { id, operator: op, value };
        }
    }

    if ("in" in rule && Array.isArray(rule.in)) {
        const args = rule.in as unknown[];
        const list = args.length > 1 && Array.isArray(args[1]) ? args[1] : [];
        return { id, operator: "in", value: list.join(", ") };
    }

    return { id, operator: "==", value: "" };
}

// ─── Component ───────────────────────────────────────────────────────────────

export function CriterionRuleBuilder({ fieldName, value, onChange, dataType, optionsList = [], label }: CriterionRuleBuilderProps) {
    const isListType = dataType === "select" || dataType === "multiselect" || dataType === "searchable_select";
    const availableOperators = isListType
        ? OPERATORS
        : OPERATORS.filter((op) => op.value !== "in");
    const [combinator, setCombinator] = useState<Combinator>("and");
    const [conditions, setConditions] = useState<Condition[]>([
        { id: generateId(), operator: "==", value: "" },
    ]);
    const [initialized, setInitialized] = useState(false);

    // Parse incoming JSON Logic value into conditions + combinator
    useEffect(() => {
        if (initialized) return;
        try {
            if (value) {
                const parsed = JSON.parse(value);
                const result = jsonLogicToConditions(parsed, fieldName);
                setConditions(result.conditions.length > 0 ? result.conditions : [{ id: generateId(), operator: "==", value: "" }]);
                setCombinator(result.combinator);
            }
        } catch {
            // Invalid JSON, keep defaults
        }
        setInitialized(true);
    }, [value, fieldName, initialized]);

    // Emit JSON Logic whenever conditions or combinator change
    const emitChange = useCallback(
        (newConditions: Condition[], newCombinator: Combinator) => {
            const jsonLogic = conditionsToJsonLogic(newConditions, newCombinator, fieldName);
            onChange(jsonLogic ? JSON.stringify(jsonLogic) : "");
        },
        [fieldName, onChange]
    );

    // Sync if fieldName changes externally
    useEffect(() => {
        if (initialized) {
            emitChange(conditions, combinator);
        }
    }, [fieldName, initialized, emitChange, conditions, combinator]);

    const updateCondition = (id: string, updates: Partial<Condition>) => {
        // Reset value when switching to/from "in" operator
        if (updates.operator) {
            const currentCondition = conditions.find((c) => c.id === id);
            if (currentCondition && currentCondition.operator !== updates.operator) {
                const switchingToIn = updates.operator === "in";
                const switchingFromIn = currentCondition.operator === "in";
                if (switchingToIn || switchingFromIn) {
                    updates.value = "";
                }
            }
        }
        const next = conditions.map((c) => (c.id === id ? { ...c, ...updates } : c));
        setConditions(next);
        emitChange(next, combinator);
    };

    const toggleInValue = (conditionId: string, option: string, currentValue: string) => {
        const selected = currentValue ? currentValue.split(", ").filter(Boolean) : [];
        const isSelected = selected.includes(option);
        const next = isSelected
            ? selected.filter((v) => v !== option)
            : [...selected, option];
        updateCondition(conditionId, { value: next.join(", ") });
    };

    const addCondition = () => {
        const next = [...conditions, { id: generateId(), operator: "==", value: "" }];
        setConditions(next);
        emitChange(next, combinator);
    };

    const removeCondition = (id: string) => {
        if (conditions.length <= 1) {
            // Reset to empty default instead of blocking
            const reset = [{ id: generateId(), operator: "==", value: "" }];
            setConditions(reset);
            emitChange(reset, combinator);
            return;
        }
        const next = conditions.filter((c) => c.id !== id);
        setConditions(next);
        emitChange(next, combinator);
    };

    const toggleCombinator = () => {
        const next: Combinator = combinator === "and" ? "or" : "and";
        setCombinator(next);
        emitChange(conditions, next);
    };

    // Build preview
    const jsonLogic = conditionsToJsonLogic(conditions, combinator, fieldName || "campo");
    const previewJson = jsonLogic ? JSON.stringify(jsonLogic, null, 2) : "—";

    return (
        <div className="space-y-3 rounded-lg border p-4 bg-muted/30">
            <div className="flex items-center justify-between">
                <Label className="text-sm font-semibold">{label || 'Regra de Elegibilidade'}</Label>
                {conditions.length > 1 && (
                    <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        onClick={toggleCombinator}
                        className="h-7 text-xs gap-1"
                    >
                        Combinar com:
                        <span className={cn(
                            "font-bold",
                            combinator === "and" ? "text-blue-600" : "text-amber-600"
                        )}>
                            {combinator === "and" ? "E (AND)" : "OU (OR)"}
                        </span>
                    </Button>
                )}
            </div>

            {/* Conditions */}
            <div className="space-y-2">
                {conditions.map((condition, idx) => (
                    <div key={condition.id}>
                        {/* Combinator pill between conditions */}
                        {idx > 0 && (
                            <div className="flex justify-center py-1">
                                <span className={cn(
                                    "text-[10px] font-bold px-2 py-0.5 rounded-full",
                                    combinator === "and"
                                        ? "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300"
                                        : "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300"
                                )}>
                                    {combinator === "and" ? "E" : "OU"}
                                </span>
                            </div>
                        )}

                        {/* Condition Row */}
                        <div className="flex items-center gap-2 rounded-md border bg-background p-2">
                            {/* Field name (read-only, auto from context) */}
                            <div
                                title={fieldName || "campo"}
                                className="flex items-center h-9 px-3 rounded-md border bg-muted text-sm text-muted-foreground w-20 shrink-0 overflow-hidden"
                            >
                                <span className="truncate">{fieldName || "campo"}</span>
                            </div>

                            {/* Operator */}
                            <Select
                                value={condition.operator}
                                onValueChange={(val) => updateCondition(condition.id, { operator: val })}
                            >
                                <SelectTrigger className="w-[160px] shrink-0">
                                    <SelectValue />
                                </SelectTrigger>
                                <SelectContent>
                                    {availableOperators.map((op) => (
                                        <SelectItem key={op.value} value={op.value}>
                                            {op.label}
                                        </SelectItem>
                                    ))}
                                </SelectContent>
                            </Select>

                            {/* Value */}
                                {condition.operator === "in" && isListType ? (
                                    <Popover>
                                        <PopoverTrigger asChild>
                                            <Button
                                                variant="outline"
                                                role="combobox"
                                                className="flex-1 justify-between font-normal h-auto min-h-[36px] py-1"
                                            >
                                                <div className="flex flex-wrap gap-1">
                                                    {condition.value ? (
                                                        condition.value.split(", ").filter(Boolean).map((v) => (
                                                            <Badge key={v} variant="secondary" className="text-xs gap-1">
                                                                {v}
                                                                <X
                                                                    className="h-3 w-3 cursor-pointer"
                                                                    onClick={(e) => {
                                                                        e.stopPropagation();
                                                                        toggleInValue(condition.id, v, condition.value);
                                                                    }}
                                                                />
                                                            </Badge>
                                                        ))
                                                    ) : (
                                                        <span className="text-muted-foreground">Selecione...</span>
                                                    )}
                                                </div>
                                                <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
                                            </Button>
                                        </PopoverTrigger>
                                        <PopoverContent className="w-[240px] p-0" align="start">
                                            <Command>
                                                <CommandList>
                                                    <CommandEmpty>Sem opções disponíveis.</CommandEmpty>
                                                    <CommandGroup>
                                                        {optionsList.map((opt) => {
                                                            const selected = condition.value ? condition.value.split(", ").filter(Boolean) : [];
                                                            const isSelected = selected.includes(opt);
                                                            return (
                                                                <CommandItem
                                                                    key={opt}
                                                                    value={opt}
                                                                    onSelect={() => toggleInValue(condition.id, opt, condition.value)}
                                                                >
                                                                    <div className={cn("flex h-4 w-4 shrink-0 items-center justify-center rounded-sm border mr-2", isSelected ? "bg-primary border-primary text-primary-foreground" : "border-muted-foreground/30")}>
                                                                        {isSelected && <Check className="h-3 w-3" />}
                                                                    </div>
                                                                    {opt}
                                                                </CommandItem>
                                                            );
                                                        })}
                                                    </CommandGroup>
                                                </CommandList>
                                            </Command>
                                        </PopoverContent>
                                    </Popover>
                                ) : (optionsList.length > 0 && (condition.operator === "==" || condition.operator === "!=")) ? (
                                    <Select
                                        value={condition.value}
                                        onValueChange={(val) => updateCondition(condition.id, { value: val })}
                                    >
                                        <SelectTrigger className="flex-1">
                                            <SelectValue placeholder="Selecione o valor..." />
                                        </SelectTrigger>
                                        <SelectContent>
                                            {optionsList.map((opt, i) => (
                                                <SelectItem key={i} value={opt}>{opt}</SelectItem>
                                            ))}
                                        </SelectContent>
                                    </Select>
                                ) : (
                                    <Input
                                        placeholder="Valor"
                                        value={condition.value}
                                        onChange={(e) => updateCondition(condition.id, { value: e.target.value })}
                                        className="flex-1"
                                    />
                                )}

                            {/* Remove */}
                            <Button
                                type="button"
                                variant="ghost"
                                size="icon"
                                className="shrink-0 h-9 w-9"
                                onClick={() => removeCondition(condition.id)}
                            >
                                <Trash2 className="h-4 w-4 text-destructive" />
                            </Button>
                        </div>
                    </div>
                ))}
            </div>

            {/* Add Condition */}
            <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={addCondition}
                className="gap-1 w-full"
            >
                <Plus className="h-3.5 w-3.5" />
                Adicionar Condição
            </Button>

            {/* JSON Preview */}
            <details className="group">
                <summary className="flex items-center gap-1 text-xs text-muted-foreground cursor-pointer hover:text-foreground">
                    <ChevronDown className="h-3 w-3 transition-transform group-open:rotate-180" />
                    Preview JSON Logic
                </summary>
                <pre className="mt-1 p-2 rounded bg-muted text-xs font-mono overflow-x-auto max-h-24">
                    {previewJson}
                </pre>
            </details>
        </div>
    );
}
