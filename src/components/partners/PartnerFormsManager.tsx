import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { PartnerOpportunity } from "@/services/partnerOpportunitiesService";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Accordion, AccordionItem, AccordionTrigger, AccordionContent } from "@/components/ui/accordion";
import { Switch } from "@/components/ui/switch";
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command";
import { cn } from "@/lib/utils";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogFooter,
} from "@/components/ui/dialog";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import {
    AlertDialog,
    AlertDialogAction,
    AlertDialogCancel,
    AlertDialogContent,
    AlertDialogDescription,
    AlertDialogFooter,
    AlertDialogHeader,
    AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Plus, Pencil, Trash2, Loader2, Code2, Check, ChevronsUpDown, X, Shield, Star, Download, Copy, GripVertical, Upload, Grid3X3 } from "lucide-react";
import { toast } from "sonner";
import { CriterionRuleBuilder } from "./CriterionRuleBuilder";
import { PhaseManagerModal } from "./PhaseManagerModal";
import * as XLSX from "xlsx";
import Papa from "papaparse";
import {
    DndContext,
    closestCenter,
    KeyboardSensor,
    PointerSensor,
    useSensor,
    useSensors,
    DragEndEvent,
    DragStartEvent,
    DragOverEvent,
    DragOverlay,
    defaultDropAnimationSideEffects
} from '@dnd-kit/core';
import {
    arrayMove,
    SortableContext,
    sortableKeyboardCoordinates,
    verticalListSortingStrategy,
    useSortable
} from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';

// ─── Types ───────────────────────────────────────────────────────────────────

interface PartnerStep {
    id: string;
    partner_id: string;
    step_name: string;
    sort_order: number;
    introduction?: string | null;
    secret_step?: boolean;
    is_iterable?: boolean;
    repeat_limit?: number | null;
    conditional_rule?: any; // JSONB storage: { field_id: string, operator: string, value: any }
    created_at?: string;
    updated_at?: string;
}

interface PartnerFormField {
    id: string;
    partner_id: string;
    step_id: string | null;
    field_name: string;
    question_text: string;
    data_type: string;
    options: any; // Using any for Json compatibility
    mapping_source: string | null;
    maskking: string | null;
    is_criterion: boolean;
    criterion_type: 'eligibility' | 'priority';
    criterion_rule: any; // Using any for Json compatibility
    conditional_rule: any; // JSONB storage: { field_id: string, operator: string, value: any }
    sort_order: number;
    optional: boolean;
    ui_component?: string | null;
    created_at: string;
    updated_at: string;
}

interface FormFieldValues {
    step_id: string;
    field_name: string;
    question_text: string;
    data_type: string;
    optionsList: string[];
    gridRows: string[];
    gridColumns: string[];
    mapping_source: string;
    maskking: string;
    is_criterion: boolean;
    criterion_type: 'eligibility' | 'priority';
    criterion_rule: string;
    conditional_rule: string; // JSON string in form
    sort_order: number;
    optional: boolean;
    ui_component: string;
}

const EMPTY_FIELD: FormFieldValues = {
    step_id: "",
    field_name: "",
    question_text: "",
    data_type: "text",
    optionsList: ["Opção 1", "Opção 2"],
    gridRows: ["Linha 1"],
    gridColumns: ["Coluna 1"],
    mapping_source: "",
    maskking: "",
    is_criterion: false,
    criterion_type: 'eligibility',
    criterion_rule: "",
    conditional_rule: "",
    sort_order: 0,
    optional: false,
    ui_component: "",
};

import { DATA_TYPES, getMappingLabel, MASK_TYPES_TEXT, MASK_TYPES_NUMBER } from "@/constants/formConstants";

// ─── Rule Helpers ──────────────────────────────────────────────────────────

const parseRule = (jsonLogic: any) => {
    if (!jsonLogic || typeof jsonLogic !== 'object') return null;
    const operator = Object.keys(jsonLogic)[0];
    const args = jsonLogic[operator];
    if (Array.isArray(args) && args.length === 2 && args[0].var) {
        return {
            field: args[0].var,
            operator,
            value: String(args[1])
        };
    }
    return null;
};

const formatRuleDisplay = (rule: any, allFields: PartnerFormField[]) => {
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

    const triggerField = allFields.find(f => f.field_name === parsed.field);
    const fieldLabel = triggerField ? triggerField.question_text : parsed.field;

    return `Exibir se [${fieldLabel}] ${opLabel} "${parsed.value}"`;
};

const serializeRule = (field: string, operator: string, value: string) => {
    if (!field) return null;
    return { [operator]: [{ var: field }, value] };
};

// ─── Sortable Components ───────────────────────────────────────────────────

function SortableStepRow({ step, onEdit, onDelete }: { step: PartnerStep, onEdit: (s: PartnerStep) => void, onDelete: (id: string) => void }) {
    const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: step.id });
    const style = {
        transform: CSS.Transform.toString(transform),
        transition,
        opacity: isDragging ? 0.5 : 1,
        position: isDragging ? "relative" as const : undefined,
        zIndex: isDragging ? 10 : 1,
    };
    return (
        <TableRow ref={setNodeRef} style={style} className={isDragging ? "bg-muted/50" : ""}>
            <TableCell className="w-[40px] px-2 text-center">
                <Button variant="ghost" size="icon" className="cursor-grab hover:bg-muted/50 h-8 w-8 focus:ring-0" {...attributes} {...listeners}>
                    <GripVertical className="h-4 w-4 text-muted-foreground" />
                </Button>
            </TableCell>
            <TableCell className="font-mono text-sm">{step.sort_order}</TableCell>
            <TableCell>{step.step_name}</TableCell>
            <TableCell>
                <div className="flex gap-1" onPointerDown={(e) => e.stopPropagation()}>
                    <Button variant="ghost" size="icon" onClick={() => onEdit(step)}>
                        <Pencil className="h-4 w-4" />
                    </Button>
                    <Button variant="ghost" size="icon" onClick={() => onDelete(step.id)}>
                        <Trash2 className="h-4 w-4 text-destructive" />
                    </Button>
                </div>
            </TableCell>
        </TableRow>
    );
}

function FieldRow({ 
    field, 
    index, 
    onEdit, 
    onDelete, 
    isDragging, 
    style, 
    attributes, 
    listeners, 
    setNodeRef,
    onClone,
    allFields
}: { 
    field: PartnerFormField, 
    index: number, 
    onEdit: (f: PartnerFormField) => void, 
    onDelete: (id: string) => void,
    onClone: (f: PartnerFormField) => void,
    allFields: PartnerFormField[],
    isDragging?: boolean,
    style?: React.CSSProperties,
    attributes?: any,
    listeners?: any,
    setNodeRef?: (node: HTMLElement | null) => void
}) {
    const ruleDisplay = formatRuleDisplay(field.conditional_rule, allFields);
    return (
        <TableRow ref={setNodeRef} style={style} className={isDragging ? "bg-muted/30 opacity-0" : ""}>
            <TableCell className="w-[40px] px-2 text-center">
                <Button variant="ghost" size="icon" className="cursor-grab hover:bg-muted/50 h-8 w-8 focus:ring-0" {...attributes} {...listeners}>
                    <GripVertical className="h-4 w-4 text-muted-foreground" />
                </Button>
            </TableCell>
            <TableCell className="text-muted-foreground w-[40px]">{index + 1}</TableCell>
            <TableCell className="font-mono text-[11px] w-[120px] truncate" title={field.field_name}>{field.field_name}</TableCell>
            <TableCell className="max-w-[250px] whitespace-normal break-words">
                <div className="flex items-start gap-2">
                    <span>{field.question_text}</span>
                    <Button
                        variant="ghost"
                        size="icon"
                        onPointerDown={(e) => e.stopPropagation()}
                        className="h-6 w-6 shrink-0 text-muted-foreground hover:text-foreground"
                        onClick={() => {
                            navigator.clipboard.writeText(field.question_text);
                            toast.success("Copiado!");
                        }}
                        title="Copiar Pergunta"
                    >
                        <Copy className="h-4 w-4" />
                    </Button>
                </div>
                {ruleDisplay && (
                    <div className="text-[10px] text-orange-600 font-medium mt-0.5 flex items-center gap-1 italic">
                        <Shield className="h-3 w-3" />
                        {ruleDisplay}
                    </div>
                )}
            </TableCell>
            <TableCell className="w-[100px]">
                <Badge variant="outline">
                    {DATA_TYPES.find((d) => d.value === field.data_type)?.label || field.data_type}
                </Badge>
            </TableCell>
            <TableCell className="w-[120px]">
                {field.maskking && field.maskking !== "none" ? (
                    <Badge variant="secondary" className="text-[10px] bg-purple-50 text-purple-700 border-purple-200">
                        {([...MASK_TYPES_TEXT, ...MASK_TYPES_NUMBER]).find(m => m.value === field.maskking)?.label || field.maskking}
                    </Badge>
                ) : (
                    <span className="text-muted-foreground">—</span>
                )}
            </TableCell>
            <TableCell className="text-xs text-muted-foreground">
                {field.mapping_source || "—"}
            </TableCell>
            <TableCell>
                {field.optional ? (
                    <span className="text-muted-foreground">Opcional</span>
                ) : (
                    <Badge variant="default" className="bg-blue-500/80">Sim</Badge>
                )}
            </TableCell>
            <TableCell>
                {field.is_criterion ? (
                    <Badge variant="default" className="bg-amber-500/80">Sim</Badge>
                ) : (
                    <span className="text-muted-foreground">Não</span>
                )}
            </TableCell>
            <TableCell>
                <div className="flex gap-1" onPointerDown={(e) => e.stopPropagation()}>
                    <Button 
                        variant="ghost" 
                        size="icon" 
                        onClick={() => onClone(field)}
                        title="Clonar este campo para outro step/parceiro"
                    >
                        <Copy className="h-4 w-4" />
                    </Button>
                    <Button variant="ghost" size="icon" onClick={() => onEdit(field)}>
                        <Pencil className="h-4 w-4" />
                    </Button>
                    <Button variant="ghost" size="icon" onClick={() => onDelete(field.id)}>
                        <Trash2 className="h-4 w-4 text-destructive" />
                    </Button>
                </div>
            </TableCell>
        </TableRow>
    );
}

function SortableFieldRow({ field, index, onEdit, onDelete, onClone, allFields }: { field: PartnerFormField, index: number, onEdit: (f: PartnerFormField) => void, onDelete: (id: string) => void, onClone: (f: PartnerFormField) => void, allFields: PartnerFormField[] }) {
    const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: field.id });
    const style = {
        transform: CSS.Transform.toString(transform),
        transition,
    };
    return (
        <FieldRow 
            field={field}
            index={index}
            onEdit={onEdit}
            onDelete={onDelete}
            onClone={onClone}
            allFields={allFields}
            isDragging={isDragging}
            style={style}
            attributes={attributes}
            listeners={listeners}
            setNodeRef={setNodeRef}
        />
    );
}

// ─── Component ───────────────────────────────────────────────────────────────

interface PartnerFormsManagerProps {
    opportunities: PartnerOpportunity[];
}

export function PartnerFormsManager({ opportunities }: PartnerFormsManagerProps) {
    const queryClient = useQueryClient();
    const [searchParams, setSearchParams] = useSearchParams();
    const selectedPartnerId = searchParams.get("partnerId") || "";

    // Dynamic Column Mappings
    const { data: dbColumns = [] } = useQuery({
        queryKey: ["mapping-columns"],
        queryFn: async () => {
            try {
                const { data, error } = await supabase.rpc("get_table_columns_for_mapping", {
                    table_names: ['user_profiles', 'user_preferences', 'user_income', 'user_enem_scores']
                });
                if (error) {
                    console.warn("RPC get_table_columns_for_mapping failed, mappings will be empty.");
                    return [];
                }
                return data.map((c: any) => ({
                    value: c.t_schema === 'auth' ? `auth.${c.t_name}.${c.c_name}` : `${c.t_name}.${c.c_name}`,
                    label: getMappingLabel(c.t_schema === 'auth' ? `auth.${c.t_name}.${c.c_name}` : `${c.t_name}.${c.c_name}`)
                }));
            } catch (err) {
                console.warn("RPC failed:", err);
                return [];
            }
        },
        staleTime: 1000 * 60 * 5, // 5 minutes cache
    });

    const mappingSources = [
        { value: "", label: "Nenhum (perguntar sempre)" },
        ...dbColumns
    ];

    const setSelectedPartnerId = (id: string) => {
        const newParams = new URLSearchParams(searchParams);
        if (id) {
            newParams.set("partnerId", id);
        } else {
            newParams.delete("partnerId");
        }
        setSearchParams(newParams);
    };

    // Field Modal State
    const [isDialogOpen, setIsDialogOpen] = useState(false);
    const [editingField, setEditingField] = useState<PartnerFormField | null>(null);
    const [formValues, setFormValues] = useState<FormFieldValues>(EMPTY_FIELD);
    const [deleteFieldId, setDeleteFieldId] = useState<string | null>(null);
    const [mappingOpen, setMappingOpen] = useState(false);
    const [isLoadingOptions, setIsLoadingOptions] = useState(false);
    const [isRulesDialogOpen, setIsRulesDialogOpen] = useState(false);

    // Step Modal State
    const [isStepDialogOpen, setIsStepDialogOpen] = useState(false);
    const [editingStep, setEditingStep] = useState<PartnerStep | null>(null);
    const [stepName, setStepName] = useState("");
    const [stepSortOrder, setStepSortOrder] = useState(0);
    const [stepIntroduction, setStepIntroduction] = useState("");
    const [stepSecret, setStepSecret] = useState(false);
    const [stepIsIterable, setStepIsIterable] = useState(false);
    const [stepRepeatLimit, setStepRepeatLimit] = useState<number | null>(null);
    const [stepConditionalRule, setStepConditionalRule] = useState("");
    const [deleteStepId, setDeleteStepId] = useState<string | null>(null);
    const [isImportFieldsDialogOpen, setIsImportFieldsDialogOpen] = useState(false);
    const [importSourcePartnerId, setImportSourcePartnerId] = useState<string>("");
    const [importSourceStepId, setImportSourceStepId] = useState<string>("");
    const [importTargetStepId, setImportTargetStepId] = useState<string>("");
    const [isImporting, setIsImporting] = useState(false);
    const [activeId, setActiveId] = useState<string | null>(null);

    const [isCloneFieldDialogOpen, setIsCloneFieldDialogOpen] = useState(false);
    const [cloneFieldTargetPartnerId, setCloneFieldTargetPartnerId] = useState<string>("");
    const [cloneFieldTargetStepId, setCloneFieldTargetStepId] = useState<string>("");
    const [cloningFieldSource, setCloningFieldSource] = useState<PartnerFormField | null>(null);
    const [isCloningSingle, setIsCloningSingle] = useState(false);

    // Conditional Logic State for steps
    const [stepHasCondition, setStepHasCondition] = useState(false);
    const [stepTriggerField, setStepTriggerField] = useState("");
    const [stepTriggerOperator, setStepTriggerOperator] = useState("==");
    const [stepTriggerValue, setStepTriggerValue] = useState("");

    // Conditional Logic State for fields
    const [fieldHasCondition, setFieldHasCondition] = useState(false);
    const [fieldTriggerField, setFieldTriggerField] = useState("");
    const [fieldTriggerOperator, setFieldTriggerOperator] = useState("==");
    const [fieldTriggerValue, setFieldTriggerValue] = useState("");

    const getUniqueFieldName = async (baseName: string, partnerId: string) => {
        const { data: existingFields } = await supabase
            .from("partner_forms")
            .select("field_name")
            .eq("partner_id", partnerId);
        
        const existingNames = new Set((existingFields || []).map(f => f.field_name.toLowerCase()));
        
        if (!existingNames.has(baseName.toLowerCase())) {
            return baseName;
        }

        let counter = 2;
        let newName = `${baseName}_${counter}`;
        while (existingNames.has(newName.toLowerCase())) {
            counter++;
            newName = `${baseName}_${counter}`;
        }
        return newName;
    };

    // ─── Queries ─────────────────────────────────────────────────────────────

    // Fetch Steps
    const { data: steps = [], isLoading: isLoadingSteps } = useQuery({
        queryKey: ["partner-steps", selectedPartnerId],
        queryFn: async () => {
            if (!selectedPartnerId) return [];
            const { data, error } = await supabase
                .from("partner_steps")
                .select("*")
                .eq("partner_id", selectedPartnerId)
                .order("sort_order", { ascending: true });
            if (error) throw error;
            return (data ?? []) as PartnerStep[];
        },
        enabled: !!selectedPartnerId,
    });

    // Fetch Fields
    const { data: fields = [], isLoading: isLoadingFields } = useQuery({
        queryKey: ["partner-forms", selectedPartnerId],
        queryFn: async () => {
            if (!selectedPartnerId) return [];
            const { data, error } = await supabase
                .from("partner_forms")
                .select("*")
                .eq("partner_id", selectedPartnerId)
                .order("sort_order", { ascending: true });
            if (error) throw error;
            return (data ?? []) as unknown as PartnerFormField[];
        },
        enabled: !!selectedPartnerId,
    });

    // ─── Mutations (Steps) ───────────────────────────────────────────────────

    const saveStepMutation = useMutation({
        mutationFn: async () => {
            const payload = {
                partner_id: selectedPartnerId,
                step_name: stepName,
                sort_order: stepSortOrder,
                introduction: stepIntroduction || null,
                secret_step: stepSecret,
                is_iterable: stepIsIterable,
                repeat_limit: stepIsIterable ? stepRepeatLimit : null,
                conditional_rule: stepHasCondition ? serializeRule(stepTriggerField, stepTriggerOperator, stepTriggerValue) : null,
            };
            if (editingStep) {
                const { error } = await supabase
                    .from("partner_steps")
                    .update(payload)
                    .eq("id", editingStep.id);
                if (error) throw error;
            } else {
                const { error } = await supabase
                    .from("partner_steps")
                    .insert(payload);
                if (error) throw error;
            }
        },
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partner-steps", selectedPartnerId] });
            toast.success(editingStep ? "Step atualizado!" : "Step criado!");
            setIsStepDialogOpen(false);
            setEditingStep(null);
            setStepName("");
            setStepSortOrder(0);
            setStepIntroduction("");
            setStepSecret(false);
            setStepIsIterable(false);
            setStepRepeatLimit(null);
            setStepHasCondition(false);
            setStepTriggerField("");
            setStepTriggerOperator("==");
            setStepTriggerValue("");
            setStepConditionalRule("");
        },
        onError: (err: any) => {
            toast.error(`Erro: ${err.message}`);
        },
    });

    const deleteStepMutation = useMutation({
        mutationFn: async (id: string) => {
            const { error } = await supabase
                .from("partner_steps")
                .delete()
                .eq("id", id);
            if (error) throw error;
        },
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partner-steps", selectedPartnerId] });
            toast.success("Step removido!");
            setDeleteStepId(null);
        },
        onError: () => toast.error("Erro ao remover step. Verifique se existem campos associados."),
    });

    // ─── Mutations (Fields) ──────────────────────────────────────────────────

    const saveMutation = useMutation({
        mutationFn: async (values: FormFieldValues) => {
            const hasOptions = values.data_type === "select" || values.data_type === "multiselect" || values.data_type === "searchable_select";
            const isGrid = values.data_type === "grid_select" || values.data_type === "grid_multiselect";
            
            // Check for duplicate field_name within the same partner (excluding the field being edited)
            const isDuplicate = fields.some(f => 
                f.field_name.toLowerCase() === values.field_name.toLowerCase() && 
                (!editingField || f.id !== editingField.id)
            );

            if (isDuplicate) {
                throw new Error(`O nome do campo "${values.field_name}" já está em uso por outro campo deste parceiro. Escolha um nome único.`);
            }

            const payload: any = {
                partner_id: selectedPartnerId,
                step_id: values.step_id || null,
                field_name: values.field_name,
                question_text: values.question_text,
                data_type: values.data_type,
                options: isGrid
                    ? { rows: values.gridRows.filter(r => r.trim() !== ""), columns: values.gridColumns.filter(c => c.trim() !== "") }
                    : hasOptions ? values.optionsList.filter(o => o.trim() !== "") : null,
                mapping_source: values.mapping_source || null,
                maskking: values.maskking || null,
                is_criterion: values.is_criterion && !!values.criterion_rule,
                criterion_type: values.is_criterion ? values.criterion_type : 'eligibility',
                criterion_rule: (values.is_criterion && values.criterion_rule)
                    ? (typeof values.criterion_rule === 'string' ? JSON.parse(values.criterion_rule) : values.criterion_rule)
                    : null,
                conditional_rule: values.conditional_rule 
                    ? (typeof values.conditional_rule === 'string' ? JSON.parse(values.conditional_rule) : values.conditional_rule) 
                    : null,
                sort_order: values.sort_order,
                optional: values.optional,
                ui_component: values.ui_component || null,
            };

            if (editingField) {
                const { error } = await supabase
                    .from("partner_forms")
                    .update(payload)
                    .eq("id", editingField.id);
                if (error) throw error;
            } else {
                const { error } = await supabase
                    .from("partner_forms")
                    .insert(payload);
                if (error) throw error;
            }
        },
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partner-forms", selectedPartnerId] });
            toast.success(editingField ? "Campo atualizado!" : "Campo criado!");
            setIsDialogOpen(false);
            setEditingField(null);
            setFormValues(EMPTY_FIELD);
        },
        onError: (err: any) => {
            toast.error(`Erro: ${err.message}`);
        },
    });

    const deleteMutation = useMutation({
        mutationFn: async (id: string) => {
            const { error } = await supabase
                .from("partner_forms")
                .delete()
                .eq("id", id);
            if (error) throw error;
        },
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partner-forms", selectedPartnerId] });
            toast.success("Campo removido!");
            setDeleteFieldId(null);
        },
        onError: () => toast.error("Erro ao remover campo."),
    });

    // ─── Handlers & Drag-and-Drop ─────────────────────────────────────────────

    const reorderStepsMutation = useMutation({
        mutationFn: async (orderedSteps: PartnerStep[]) => {
            const updates = orderedSteps.map((s, index) => ({
                id: s.id,
                partner_id: s.partner_id,
                step_name: s.step_name,
                sort_order: index + 1,
                introduction: s.introduction || null,
                secret_step: s.secret_step || false,
                is_iterable: s.is_iterable || false,
                repeat_limit: s.repeat_limit || null,
                conditional_rule: s.conditional_rule || null,
            }));
            const { error } = await supabase
                .from("partner_steps")
                .upsert(updates, { onConflict: "id" });
            if (error) throw error;
        },
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partner-steps", selectedPartnerId] });
        },
        onError: (err: any) => {
            toast.error(`Erro ao reordenar Steps: ${err.message}`);
        }
    });

    const reorderFieldsMutation = useMutation({
        mutationFn: async (orderedFields: PartnerFormField[]) => {
            const updates = orderedFields.map((f) => ({
                id: f.id,
                partner_id: f.partner_id,
                step_id: f.step_id,
                field_name: f.field_name,
                question_text: f.question_text,
                data_type: f.data_type,
                options: f.options,
                mapping_source: f.mapping_source,
                maskking: f.maskking,
                is_criterion: f.is_criterion,
                criterion_rule: f.criterion_rule,
                conditional_rule: f.conditional_rule,
                sort_order: f.sort_order,
                optional: f.optional,
            }));
            const { error } = await supabase
                .from("partner_forms")
                .upsert(updates, { onConflict: "id" });
            if (error) throw error;
        },
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partner-forms", selectedPartnerId] });
        },
        onError: (err: any) => {
            toast.error(`Erro ao reordenar Campos: ${err.message}`);
        }
    });

    const getRuleDependencies = (rule: any): string[] => {
        if (!rule || typeof rule !== 'object') return [];
        const deps: string[] = [];
        if (rule.var && typeof rule.var === 'string') {
            deps.push(rule.var);
        } else {
            Object.values(rule).forEach(v => {
                if (Array.isArray(v)) {
                    v.forEach(item => deps.push(...getRuleDependencies(item)));
                } else if (v && typeof v === 'object') {
                    deps.push(...getRuleDependencies(v));
                }
            });
        }
        return [...new Set(deps)];
    };

    const validateReorder = (newFields: PartnerFormField[]) => {
        for (let i = 0; i < newFields.length; i++) {
            const field = newFields[i];
            if (field.conditional_rule) {
                const triggerNames = getRuleDependencies(field.conditional_rule);
                for (const triggerName of triggerNames) {
                    const triggerIndex = newFields.findIndex(f => f.field_name === triggerName);
                    if (triggerIndex !== -1 && triggerIndex >= i) {
                        toast.error(`Violação de dependência: O campo "${field.field_name}" depende de "${triggerName}", que está posicionado depois dele.`);
                        return false;
                    }
                }
            }
        }
        return true;
    };

    const sensors = useSensors(
        useSensor(PointerSensor, { activationConstraint: { distance: 5 } }),
        useSensor(KeyboardSensor, {
            coordinateGetter: sortableKeyboardCoordinates,
        })
    );

    const handleDragEndSteps = (event: DragEndEvent) => {
        const { active, over } = event;
        if (over && active.id !== over.id) {
            const oldIndex = steps.findIndex(s => s.id === active.id);
            const newIndex = steps.findIndex(s => s.id === over.id);
            const newSteps = arrayMove(steps, oldIndex, newIndex);

            // Re-assign sort_order locally for optimistic UI
            const updatedLocal = newSteps.map((s, idx) => ({ ...s, sort_order: idx + 1 }));

            queryClient.setQueryData(["partner-steps", selectedPartnerId], updatedLocal);
            reorderStepsMutation.mutate(newSteps);
        }
    };

    const handleDragStart = (event: DragStartEvent) => {
        setActiveId(event.active.id as string);
    };

    const handleDragOver = (event: DragOverEvent) => {
        const { active, over } = event;
        if (!over) return;

        const activeId = active.id as string;
        const overId = over.id as string;

        if (activeId === overId) return;

        const activeField = fields.find(f => f.id === activeId);
        const overField = fields.find(f => f.id === overId);

        if (!activeField || !overField) return;

        // If moving between different steps, we can optimistically update the UI
        // This makes the transition smoother as the item jumps to the new list
        if (activeField.step_id !== overField.step_id) {
            const updatedFields = fields.map(f => {
                if (f.id === activeId) {
                    return { ...f, step_id: overField.step_id };
                }
                return f;
            });
            queryClient.setQueryData(["partner-forms", selectedPartnerId], updatedFields);
        }
    };

    const handleDragEndFields = (event: DragEndEvent) => {
        setActiveId(null);
        const { active, over } = event;
        if (!over || active.id === over.id) return;

        const activeFieldId = active.id as string;
        const overFieldId = over.id as string;

        const activeField = fields.find(f => f.id === activeFieldId);
        const overField = fields.find(f => f.id === overFieldId);

        if (!activeField || !overField) return;

        // If they are in the same step, just reorder within the group
        if (activeField.step_id === overField.step_id) {
            const groupFields = fields.filter(f => f.step_id === activeField.step_id);
            const oldIndex = groupFields.findIndex(f => f.id === activeFieldId);
            const newIndex = groupFields.findIndex(f => f.id === overFieldId);
            
            const reorderedGroup = arrayMove(groupFields, oldIndex, newIndex)
                .map((f, idx) => ({ ...f, sort_order: idx + 1 }));
            
            // Update local state and DB
            const updatedFields = fields.map(f => {
                if (f.step_id === activeField.step_id) {
                    const idx = reorderedGroup.findIndex(rg => rg.id === f.id);
                    return reorderedGroup[idx];
                }
                return f;
            });

            queryClient.setQueryData(["partner-forms", selectedPartnerId], updatedFields);

            if (!validateReorder(updatedFields)) {
                queryClient.invalidateQueries({ queryKey: ["partner-forms", selectedPartnerId] });
                return;
            }

            reorderFieldsMutation.mutate(reorderedGroup);
        } else {
            // Cross-step move
            const sourceStepId = activeField.step_id;
            const destStepId = overField.step_id;

            const updatedActiveField = { ...activeField, step_id: destStepId };
            
            // Re-order destination step
            const destFields = fields.filter(f => f.step_id === destStepId);
            const overIndex = destFields.findIndex(f => f.id === overFieldId);
            
            const newDestFields = [...destFields];
            newDestFields.splice(overIndex, 0, updatedActiveField);
            
            // Re-index both source and destination
            const newSourceFields = fields.filter(f => f.step_id === sourceStepId && f.id !== activeFieldId);
            
            const finalFields = fields.map(f => {
                if (f.id === activeFieldId) return { ...updatedActiveField, sort_order: overIndex + 1 };
                
                if (f.step_id === sourceStepId) {
                    const idx = newSourceFields.findIndex(ns => ns.id === f.id);
                    return { ...f, sort_order: idx + 1 };
                }
                
                if (f.step_id === destStepId) {
                    const idx = newDestFields.findIndex(nd => nd.id === f.id);
                    return { ...f, sort_order: idx + 1 };
                }
                
                return f;
            });

            queryClient.setQueryData(["partner-forms", selectedPartnerId], finalFields);
            
            // Validate cross-step move
            if (!validateReorder(finalFields)) {
                // Revert on error
                queryClient.invalidateQueries({ queryKey: ["partner-forms", selectedPartnerId] });
                return;
            }

            // Persist all fields in source and destination
            const toUpdate = [
                ...newSourceFields.map((f, i) => ({ ...f, sort_order: i + 1 })),
                ...newDestFields.map((f, i) => ({ ...f, sort_order: i + 1 }))
            ];
            reorderFieldsMutation.mutate(toUpdate);
        }
    };

    // ─── Handlers (Steps) ────────────────────────────────────────────────────

    const handleAddStep = () => {
        setEditingStep(null);
        setStepName("");
        setStepSortOrder(steps.length + 1);
        setStepIntroduction("");
        setStepSecret(false);
        setStepIsIterable(false);
        setStepRepeatLimit(null);
        setStepConditionalRule("");
        setIsStepDialogOpen(true);
    };

    const handleEditStep = (step: PartnerStep) => {
        setEditingStep(step);
        setStepName(step.step_name);
        setStepSortOrder(step.sort_order);
        setStepIntroduction(step.introduction || "");
        setStepSecret(step.secret_step || false);
        setStepIsIterable(step.is_iterable || false);
        setStepRepeatLimit(step.repeat_limit || null);
        
        const rule = parseRule(step.conditional_rule);
        if (rule) {
            setStepHasCondition(true);
            setStepTriggerField(rule.field);
            setStepTriggerOperator(rule.operator);
            setStepTriggerValue(rule.value);
        } else {
            setStepHasCondition(false);
            setStepTriggerField("");
        }
        setStepConditionalRule(step.conditional_rule ? JSON.stringify(step.conditional_rule, null, 2) : "");
        setIsStepDialogOpen(true);
    };

    const handleSaveStep = () => {
        if (!stepName.trim()) {
            toast.error("Nome do step é obrigatório.");
            return;
        }
        saveStepMutation.mutate();
    };

    const handleImportFields = async () => {
        if (!importSourceStepId || !importTargetStepId) {
            toast.error("Selecione a origem e o destino.");
            return;
        }

        setIsImporting(true);
        try {
            // Fetch fields from source step
            const { data, error: fetchError } = await supabase
                .from("partner_forms")
                .select("*")
                .eq("step_id", importSourceStepId)
                .order("sort_order", { ascending: true });

            if (fetchError) throw fetchError;
            const sourceFields = (data || []) as unknown as PartnerFormField[];
            if (sourceFields.length === 0) {
                toast.info("A etapa de origem não possui campos.");
                return;
            }

            // Prepare new fields with unique names
            const { data: destFields } = await supabase
                .from("partner_forms")
                .select("field_name")
                .eq("partner_id", selectedPartnerId);
            
            const existingNames = new Set((destFields || []).map(f => f.field_name.toLowerCase()));
            
            const newFields = sourceFields.map((f, idx) => {
                const baseName = f.field_name;
                let finalName = baseName;
                
                if (existingNames.has(finalName.toLowerCase())) {
                    let counter = 2;
                    finalName = `${baseName}_${counter}`;
                    while (existingNames.has(finalName.toLowerCase())) {
                        counter++;
                        finalName = `${baseName}_${counter}`;
                    }
                }
                
                // Add to set to prevent internal collisions within the imported batch
                existingNames.add(finalName.toLowerCase());

                return {
                    partner_id: selectedPartnerId,
                    step_id: importTargetStepId === "orphan" ? null : importTargetStepId,
                    field_name: finalName,
                    question_text: f.question_text,
                    data_type: f.data_type,
                    options: f.options,
                    mapping_source: f.mapping_source,
                    maskking: f.maskking,
                    is_criterion: f.is_criterion,
                    criterion_rule: f.criterion_rule,
                    sort_order: fields.length + idx + 1,
                    optional: f.optional ?? false,
                };
            });

            const { error: insertError } = await supabase
                .from("partner_forms")
                .insert(newFields);

            if (insertError) throw insertError;

            toast.success(`${newFields.length} campos importados com sucesso!`);
            queryClient.invalidateQueries({ queryKey: ["partner-forms", selectedPartnerId] });
            setIsImportFieldsDialogOpen(false);
            setImportSourceStepId("");
        } catch (err: any) {
            toast.error(`Erro ao importar: ${err.message}`);
        } finally {
            setIsImporting(false);
        }
    };

    const handleCloneSingleField = async () => {
        if (!cloningFieldSource || !cloneFieldTargetPartnerId || !cloneFieldTargetStepId) {
            toast.error("Selecione o destino.");
            return;
        }

        setIsCloningSingle(true);
        try {
            // Calculate sort order for target step
            const { data: targetFields } = await supabase
                .from("partner_forms")
                .select("sort_order")
                .eq("partner_id", cloneFieldTargetPartnerId)
                .eq("step_id", cloneFieldTargetStepId === "orphan" ? null : cloneFieldTargetStepId)
                .order("sort_order", { ascending: false })
                .limit(1);

            const nextOrder = (targetFields?.[0]?.sort_order || 0) + 1;

            const uniqueName = await getUniqueFieldName(cloningFieldSource.field_name, cloneFieldTargetPartnerId);

            const newField = {
                partner_id: cloneFieldTargetPartnerId,
                step_id: cloneFieldTargetStepId === "orphan" ? null : cloneFieldTargetStepId,
                field_name: uniqueName,
                question_text: cloningFieldSource.question_text,
                data_type: cloningFieldSource.data_type,
                options: cloningFieldSource.options,
                mapping_source: cloningFieldSource.mapping_source,
                maskking: cloningFieldSource.maskking,
                is_criterion: cloningFieldSource.is_criterion,
                criterion_rule: cloningFieldSource.criterion_rule,
                sort_order: nextOrder,
                optional: cloningFieldSource.optional ?? false,
            };

            const { error: insertError } = await supabase
                .from("partner_forms")
                .insert(newField);

            if (insertError) throw insertError;

            toast.success(`Campo "${cloningFieldSource.field_name}" clonado com sucesso!`);
            
            // Only invalidate if current partner matches target
            if (cloneFieldTargetPartnerId === selectedPartnerId) {
                queryClient.invalidateQueries({ queryKey: ["partner-forms", selectedPartnerId] });
            }
            
            setIsCloneFieldDialogOpen(false);
            setCloningFieldSource(null);
        } catch (err: any) {
            toast.error(`Erro ao clonar: ${err.message}`);
        } finally {
            setIsCloningSingle(false);
        }
    };

    const { data: importSourceSteps = [], isLoading: isLoadingImportSteps } = useQuery({
        queryKey: ["import-source-steps", importSourcePartnerId],
        queryFn: async () => {
            if (!importSourcePartnerId) return [];
            const { data, error } = await supabase
                .from("partner_steps")
                .select("*")
                .eq("partner_id", importSourcePartnerId)
                .order("sort_order", { ascending: true });
            if (error) throw error;
            return data || [];
        },
        enabled: isImportFieldsDialogOpen && !!importSourcePartnerId,
    });

    const { data: cloneTargetSteps = [], isLoading: isLoadingCloneTargetSteps } = useQuery({
        queryKey: ["clone-target-steps", cloneFieldTargetPartnerId],
        queryFn: async () => {
            if (!cloneFieldTargetPartnerId) return [];
            const { data, error } = await supabase
                .from("partner_steps")
                .select("*")
                .eq("partner_id", cloneFieldTargetPartnerId)
                .order("sort_order", { ascending: true });
            if (error) throw error;
            return data || [];
        },
        enabled: isCloneFieldDialogOpen && !!cloneFieldTargetPartnerId,
    });

    // ─── Helpers ──────────────────────────────────────────────────────────────

    // Group fields by step, ordered by step sort_order
    const fieldsByStep = (() => {
        const groups: { step: PartnerStep | null; fields: PartnerFormField[] }[] = [];
        // Add one group per step (in sort_order)
        for (const step of steps) {
            groups.push({ step, fields: fields.filter(f => f.step_id === step.id) });
        }
        // Add orphan fields (no step)
        const orphans = fields.filter(f => !f.step_id || !steps.find(s => s.id === f.step_id));
        if (orphans.length > 0) {
            groups.push({ step: null, fields: orphans });
        }
        return groups;
    })();

    // ─── Handlers (Fields) ───────────────────────────────────────────────────

    const handleAdd = (preSelectedStepId?: string) => {
        setEditingField(null);
        setFormValues({
            ...EMPTY_FIELD,
            step_id: preSelectedStepId || "",
            sort_order: fields.length,
        });
        setIsDialogOpen(true);
    };

    const handleEdit = (field: PartnerFormField) => {
        setEditingField(field);

        let optionsList = ["Opção 1", "Opção 2"];
        let gridRows = ["Linha 1"];
        let gridColumns = ["Coluna 1"];

        const isGrid = field.data_type === "grid_select" || field.data_type === "grid_multiselect";

        if (isGrid && field.options && typeof field.options === "object" && !Array.isArray(field.options)) {
            const gridOpts = field.options as { rows?: string[]; columns?: string[] };
            gridRows = gridOpts.rows || ["Linha 1"];
            gridColumns = gridOpts.columns || ["Coluna 1"];
        } else if (field.options && Array.isArray(field.options) && field.options.length > 0) {
            optionsList = field.options as string[];
        }

        const rule = parseRule(field.conditional_rule);
        if (rule) {
            setFieldHasCondition(true);
            setFieldTriggerField(rule.field);
            setFieldTriggerOperator(rule.operator);
            setFieldTriggerValue(rule.value);
        } else {
            setFieldHasCondition(false);
            setFieldTriggerField("");
        }

        setFormValues({
            step_id: field.step_id || "",
            field_name: field.field_name,
            question_text: field.question_text,
            data_type: field.data_type,
            optionsList: optionsList,
            gridRows: gridRows,
            gridColumns: gridColumns,
            mapping_source: field.mapping_source || "",
            maskking: field.maskking || "",
            is_criterion: field.is_criterion,
            criterion_type: field.criterion_type === 'priority' ? 'priority' : 'eligibility',
            criterion_rule: field.criterion_rule ? JSON.stringify(field.criterion_rule, null, 2) : "",
            conditional_rule: field.conditional_rule ? JSON.stringify(field.conditional_rule, null, 2) : "",
            sort_order: field.sort_order,
            optional: field.optional ?? false,
            ui_component: field.ui_component || "",
        });
        setIsDialogOpen(true);
    };

    const handleSave = () => {
        if (!formValues.field_name || !formValues.question_text) {
            toast.error("Nome do campo e texto da pergunta são obrigatórios.");
            return;
        }

        const condRule = fieldHasCondition ? serializeRule(fieldTriggerField, fieldTriggerOperator, fieldTriggerValue) : null;

        saveMutation.mutate({
            ...formValues,
            conditional_rule: condRule as any
        });
    };

    const updateOption = (index: number, val: string) => {
        const newOptions = [...formValues.optionsList];
        newOptions[index] = val;
        setFormValues({ ...formValues, optionsList: newOptions });
    };

    const removeOption = (index: number) => {
        const newOptions = formValues.optionsList.filter((_, i) => i !== index);
        setFormValues({ ...formValues, optionsList: newOptions });
    };

    const addOption = () => {
        setFormValues({ ...formValues, optionsList: [...formValues.optionsList, ""] });
    };

    const handleImportOptions = () => {
        const input = document.createElement("input");
        input.type = "file";
        input.accept = ".csv,.xlsx,.xls";
        input.onchange = async (e) => {
            const file = (e.target as HTMLInputElement).files?.[0];
            if (!file) return;

            try {
                let importedValues: string[] = [];

                if (file.name.endsWith(".csv")) {
                    const text = await file.text();
                    const result = Papa.parse(text, { header: false, skipEmptyLines: true });
                    importedValues = (result.data as string[][])
                        .map((row) => (row[0] ?? "").toString().trim())
                        .filter((v) => v !== "");
                } else {
                    const buffer = await file.arrayBuffer();
                    const workbook = XLSX.read(buffer, { type: "array" });
                    const sheet = workbook.Sheets[workbook.SheetNames[0]];
                    const rows = XLSX.utils.sheet_to_json<string[]>(sheet, { header: 1 });
                    importedValues = rows
                        .map((row) => (row[0] ?? "").toString().trim())
                        .filter((v) => v !== "");
                }

                if (importedValues.length === 0) {
                    toast.info("Nenhum valor encontrado na coluna A do arquivo.");
                    return;
                }

                const existingSet = new Set(formValues.optionsList.filter((o) => o.trim() !== ""));
                const newValues = importedValues.filter((v) => !existingSet.has(v));
                const merged = [...formValues.optionsList.filter((o) => o.trim() !== ""), ...newValues];

                setFormValues((prev) => ({ ...prev, optionsList: merged }));
                toast.success(`${newValues.length} nova(s) opção(ões) importada(s)!`);
            } catch (err: any) {
                toast.error(`Erro ao importar arquivo: ${err.message}`);
            }
        };
        input.click();
    };

    const loadOptionsFromDB = async () => {
        if (!formValues.mapping_source) return;
        const [table, column] = formValues.mapping_source.split(".");
        if (!table || !column) return;

        setIsLoadingOptions(true);
        try {
            const { data, error } = await supabase
                .from(table as any)
                .select(column);

            if (error) throw error;

            const uniqueValues = [
                ...new Set(
                    (data || [])
                        .map((row: any) => row[column])
                        .filter((v: any) => v != null && v !== "")
                        .flatMap((v: any) => (Array.isArray(v) ? v : [v]))
                        .map((v: any) => String(v))
                ),
            ].sort();

            if (uniqueValues.length === 0) {
                toast.info("Nenhum valor encontrado no banco para esse campo.");
                return;
            }

            setFormValues((prev) => ({ ...prev, optionsList: uniqueValues }));
            toast.success(`${uniqueValues.length} opções carregadas do banco!`);
        } catch (err: any) {
            toast.error(`Erro ao carregar opções: ${err.message}`);
        } finally {
            setIsLoadingOptions(false);
        }
    };

    // ─── Render ──────────────────────────────────────────────────────────────

    return (
        <div className="space-y-6">
            {/* Opportunity Selector */}
            <div className="flex items-end gap-4">
                <div className="flex-1 max-w-sm space-y-2">
                    <Label>Selecione uma Oportunidade</Label>
                    <Select value={selectedPartnerId} onValueChange={setSelectedPartnerId}>
                        <SelectTrigger>
                            <SelectValue placeholder="Escolha uma oportunidade..." />
                        </SelectTrigger>
                        <SelectContent>
                            {opportunities.map((opp) => (
                                <SelectItem key={opp.id} value={opp.id}>
                                    {opp.name}
                                    {opp.institution_name && opp.institution_name !== opp.name
                                        ? ` — ${opp.institution_name}`
                                        : ""}
                                </SelectItem>
                            ))}
                        </SelectContent>
                    </Select>
                </div>
            </div>

            {selectedPartnerId && (
                <>
                    {/* Eligibility Rules Summary Button */}
                    {(() => {
                        const criterionFields = fields.filter((f) => f.is_criterion);
                        return (
                            <div className="flex items-center gap-3">
                                <Button
                                    variant="outline"
                                    className="gap-2"
                                    onClick={() => setIsRulesDialogOpen(true)}
                                >
                                    <Shield className="h-4 w-4" />
                                    Critérios de Elegibilidade
                                    {criterionFields.length > 0 && (
                                        <Badge variant="secondary" className="ml-1">
                                            {criterionFields.length}
                                        </Badge>
                                    )}
                                </Button>
                                
                                <PhaseManagerModal 
                                    opportunityId={selectedPartnerId}
                                    opportunityName={opportunities.find(o => o.id === selectedPartnerId)?.name || "Oportunidade"}
                                />
                            </div>
                        );
                    })()}

                    {/* Criteria Rules Dialog — 2 sections: Eligibility + Priority */}
                    <Dialog open={isRulesDialogOpen} onOpenChange={setIsRulesDialogOpen}>
                        <DialogContent className="max-w-2xl max-h-[80vh] overflow-y-auto">
                            <DialogHeader>
                                <DialogTitle className="flex items-center gap-2">
                                    <Shield className="h-5 w-5" />
                                    Critérios de Seleção
                                </DialogTitle>
                            </DialogHeader>
                            <div className="py-2 space-y-6">
                                {(() => {
                                    const allCriterionFields = fields.filter((f) => f.is_criterion);
                                    if (allCriterionFields.length === 0) {
                                        return (
                                            <div className="text-center py-8 text-muted-foreground border border-dashed rounded-md">
                                                Nenhum campo com critério configurado.
                                            </div>
                                        );
                                    }

                                    const eligibilityFields = allCriterionFields.filter((f) => f.criterion_type !== 'priority');
                                    const priorityFields = allCriterionFields.filter((f) => f.criterion_type === 'priority');

                                    const renderCriterionTable = (criterionFields: typeof allCriterionFields) => (
                                        <div className="rounded-md border overflow-auto">
                                            <Table>
                                                <TableHeader>
                                                    <TableRow>
                                                        <TableHead>Campo</TableHead>
                                                        <TableHead>Etapa</TableHead>
                                                        <TableHead>Regra</TableHead>
                                                        <TableHead className="w-[60px]">Editar</TableHead>
                                                    </TableRow>
                                                </TableHeader>
                                                <TableBody>
                                                    {criterionFields.map((field) => {
                                                        const step = steps.find((s) => s.id === field.step_id);
                                                        const rulePreview = field.criterion_rule
                                                            ? JSON.stringify(field.criterion_rule)
                                                            : "—";
                                                        return (
                                                            <TableRow key={field.id}>
                                                                <TableCell className="font-mono text-sm">
                                                                    {field.field_name}
                                                                </TableCell>
                                                                <TableCell className="text-sm text-muted-foreground">
                                                                    {step ? step.step_name : "—"}
                                                                </TableCell>
                                                                <TableCell className="max-w-[300px]">
                                                                    <code className="text-xs bg-muted px-2 py-1 rounded break-all">
                                                                        {rulePreview}
                                                                    </code>
                                                                </TableCell>
                                                                <TableCell>
                                                                    <Button
                                                                        variant="ghost"
                                                                        size="icon"
                                                                        onClick={() => {
                                                                            setIsRulesDialogOpen(false);
                                                                            handleEdit(field);
                                                                        }}
                                                                    >
                                                                        <Pencil className="h-4 w-4" />
                                                                    </Button>
                                                                </TableCell>
                                                            </TableRow>
                                                        );
                                                    })}
                                                </TableBody>
                                            </Table>
                                        </div>
                                    );

                                    return (
                                        <>
                                            {/* Section 1: Eligibility */}
                                            <div>
                                                <h4 className="text-sm font-semibold flex items-center gap-2 mb-2">
                                                    <Shield className="h-4 w-4 text-red-500" />
                                                    Critérios de Elegibilidade
                                                    <span className="text-xs text-muted-foreground font-normal">(eliminatório)</span>
                                                </h4>
                                                {eligibilityFields.length > 0
                                                    ? renderCriterionTable(eligibilityFields)
                                                    : <p className="text-sm text-muted-foreground italic pl-6">Nenhum critério de elegibilidade configurado.</p>
                                                }
                                            </div>

                                            {/* Section 2: Priority */}
                                            <div>
                                                <h4 className="text-sm font-semibold flex items-center gap-2 mb-2">
                                                    <Star className="h-4 w-4 text-yellow-500" />
                                                    Critérios de Priorização
                                                    <span className="text-xs text-muted-foreground font-normal">(preferencial)</span>
                                                </h4>
                                                {priorityFields.length > 0
                                                    ? renderCriterionTable(priorityFields)
                                                    : <p className="text-sm text-muted-foreground italic pl-6">Nenhum critério de priorização configurado.</p>
                                                }
                                            </div>
                                        </>
                                    );
                                })()}
                            </div>
                        </DialogContent>
                    </Dialog>

                    {/* Steps Table */}
                    <Card>
                        <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                            <div className="space-y-1">
                                <CardTitle className="text-lg">Etapas do Formulário (Steps)</CardTitle>
                                <CardDescription>
                                    Crie blocos visuais para organizar as perguntas durante a entrevista.
                                </CardDescription>
                            </div>
                            <Button onClick={handleAddStep} size="sm" className="gap-2">
                                <Plus className="h-4 w-4" />
                                Novo Step
                            </Button>
                        </CardHeader>
                        <CardContent>
                            {isLoadingSteps ? (
                                <div className="flex justify-center py-4">
                                    <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
                                </div>
                            ) : steps.length === 0 ? (
                                <div className="text-center py-4 text-sm text-muted-foreground">
                                    Nenhum step configurado. Você pode cadastrar perguntas sem steps, mas é recomendado organizá-las.
                                </div>
                            ) : (
                                <div className="rounded-md border overflow-auto">
                                    <Table>
                                        <TableHeader>
                                            <TableRow>
                                                <TableHead className="w-[40px] px-2"></TableHead>
                                                <TableHead className="w-[80px]">Ordem</TableHead>
                                                <TableHead>Nome do Step</TableHead>
                                                <TableHead className="w-[100px]">Ações</TableHead>
                                            </TableRow>
                                        </TableHeader>
                                        <TableBody>
                                            <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={handleDragEndSteps}>
                                                <SortableContext items={steps.map(s => s.id)} strategy={verticalListSortingStrategy}>
                                                    {steps.map((step) => (
                                                        <SortableStepRow
                                                            key={step.id}
                                                            step={step}
                                                            onEdit={handleEditStep}
                                                            onDelete={setDeleteStepId}
                                                        />
                                                    ))}
                                                </SortableContext>
                                            </DndContext>
                                        </TableBody>
                                    </Table>
                                </div>
                            )}
                        </CardContent>
                    </Card>

                    {/* Fields organized by Step Accordions */}
                    <Card>
                        <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                            <div className="space-y-1">
                                <CardTitle className="text-lg">Campos do Formulário</CardTitle>
                                <CardDescription>
                                    {fields.length} campo(s) configurado(s). A Cloudinha usará esses campos para entrevistar o estudante.
                                </CardDescription>
                            </div>
                        </CardHeader>
                        <CardContent>
                            {isLoadingFields ? (
                                <div className="flex justify-center py-8">
                                    <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
                                </div>
                            ) : fieldsByStep.length === 0 ? (
                                <div className="text-center py-8 text-muted-foreground border border-dashed rounded-md">
                                    Nenhum campo configurado. Crie steps e adicione campos a eles.
                                </div>
                            ) : (
                                <DndContext 
                                    sensors={sensors} 
                                    collisionDetection={closestCenter} 
                                    onDragStart={handleDragStart}
                                    onDragOver={handleDragOver}
                                    onDragEnd={handleDragEndFields}
                                >
                                    <Accordion type="multiple" defaultValue={fieldsByStep.map((_, i) => `step-${i}`)} className="w-full">
                                    {fieldsByStep.map((group, groupIdx) => (
                                        <AccordionItem key={group.step?.id || "orphan"} value={`step-${groupIdx}`}>
                                            <AccordionTrigger className="hover:no-underline px-1">
                                                <div className="flex items-center gap-3">
                                                    <Badge variant={group.step ? "default" : "secondary"} className="text-sm">
                                                        {group.step ? `${group.step.sort_order}. ${group.step.step_name}` : "Sem Step Associado"}
                                                    </Badge>
                                                    {group.step && (
                                                        <Button
                                                            variant="ghost"
                                                            size="icon"
                                                            className="h-6 w-6"
                                                            onClick={(e) => {
                                                                e.stopPropagation();
                                                                handleEditStep(group.step!);
                                                            }}
                                                        >
                                                            <Pencil className="h-3 w-3" />
                                                        </Button>
                                                    )}
                                                    <span className="text-xs text-muted-foreground">
                                                        {group.fields.length} campo(s)
                                                    </span>
                                                </div>
                                            </AccordionTrigger>
                                            <AccordionContent>
                                                <div className="space-y-3">
                                                    {group.fields.length === 0 ? (
                                                        <div className="text-center py-4 text-sm text-muted-foreground border border-dashed rounded-md">
                                                            Nenhum campo neste step.
                                                        </div>
                                                    ) : (
                                                        <div className="rounded-md border overflow-auto">
                                                            <Table>
                                                                <TableHeader>
                                                                    <TableRow>
                                                                        <TableHead className="w-[40px] px-2"></TableHead>
                                                                        <TableHead className="w-[40px]">#</TableHead>
                                                                        <TableHead className="w-[120px]">Campo</TableHead>
                                                                        <TableHead>Pergunta</TableHead>
                                                                        <TableHead className="w-[100px]">Tipo</TableHead>
                                                                        <TableHead className="w-[120px]">Máscara</TableHead>
                                                                        <TableHead>Auto-Fill</TableHead>
                                                                        <TableHead>Obrigatório</TableHead>
                                                                        <TableHead>Critério</TableHead>
                                                                        <TableHead className="w-[100px]">Ações</TableHead>
                                                                    </TableRow>
                                                                </TableHeader>
                                                                <TableBody>
                                                                    <SortableContext items={group.fields.map(f => f.id)} strategy={verticalListSortingStrategy}>
                                                                        {group.fields.map((field, idx) => (
                                                                                <SortableFieldRow
                                                                                    key={field.id}
                                                                                    field={field}
                                                                                    index={idx}
                                                                                    onEdit={handleEdit}
                                                                                    onDelete={setDeleteFieldId}
                                                                                    onClone={(f) => {
                                                                                        setCloningFieldSource(f);
                                                                                        setCloneFieldTargetPartnerId(f.partner_id);
                                                                                        setCloneFieldTargetStepId(f.step_id || "orphan");
                                                                                        setIsCloneFieldDialogOpen(true);
                                                                                    }}
                                                                                    allFields={fields}
                                                                                />
                                                                            ))}
                                                                    </SortableContext>
                                                                </TableBody>
                                                            </Table>
                                                        </div>
                                                    )}
                                                    <div className="flex gap-2">
                                                        <Button
                                                            variant="outline"
                                                            size="sm"
                                                            className="flex-1 border-dashed gap-2"
                                                            onClick={() => handleAdd(group.step?.id)}
                                                        >
                                                            <Plus className="h-4 w-4" />
                                                            Novo Campo
                                                        </Button>
                                                        <Button
                                                            variant="secondary"
                                                            size="sm"
                                                            className="gap-2"
                                                            onClick={() => {
                                                                setImportTargetStepId(group.step?.id || "orphan");
                                                                setIsImportFieldsDialogOpen(true);
                                                            }}
                                                        >
                                                            <Download className="h-4 w-4" />
                                                            Importar campos
                                                        </Button>
                                                    </div>
                                                </div>
                                            </AccordionContent>
                                        </AccordionItem>
                                    ))}
                                </Accordion>

                                <DragOverlay dropAnimation={{
                                    sideEffects: defaultDropAnimationSideEffects({
                                        styles: {
                                            active: {
                                                opacity: '0.4',
                                            },
                                        },
                                    }),
                                }}>
                                    {activeId ? (
                                        <div className="rounded-md border bg-white shadow-xl opacity-90 overflow-hidden">
                                            <Table>
                                                <TableBody>
                                                    <FieldRow 
                                                        field={fields.find(f => f.id === activeId)!} 
                                                        index={fields.findIndex(f => f.id === activeId)}
                                                        onEdit={() => {}}
                                                        onDelete={() => {}}
                                                        onClone={() => {}}
                                                        allFields={fields}
                                                    />
                                                </TableBody>
                                            </Table>
                                        </div>
                                    ) : null}
                                </DragOverlay>
                            </DndContext>
                        )}
                        </CardContent>
                    </Card>
                </>
            )}

            <Dialog open={isStepDialogOpen} onOpenChange={setIsStepDialogOpen}>
                <DialogContent className="max-w-3xl max-h-[90vh] overflow-y-auto">
                    <DialogHeader>
                        <DialogTitle>{editingStep ? "Editar Step" : "Novo Step"}</DialogTitle>
                    </DialogHeader>
                    <div className="space-y-4 py-4">
                        <div className="space-y-2">
                            <Label>Nome do Step</Label>
                            <Input
                                placeholder="Ex: Dados Pessoais"
                                value={stepName}
                                onChange={(e) => setStepName(e.target.value)}
                            />
                        </div>
                        <div className="space-y-2">
                            <Label>Ordem de Exibição</Label>
                            <Input
                                type="number"
                                value={stepSortOrder}
                                onChange={(e) => setStepSortOrder(parseInt(e.target.value) || 0)}
                            />
                        </div>
                        <div className="space-y-2">
                            <Label>Introdução (opcional)</Label>
                            <Textarea
                                placeholder="Texto exibido antes das perguntas"
                                value={stepIntroduction}
                                onChange={(e) => setStepIntroduction(e.target.value)}
                                className="min-h-[100px]"
                            />
                        </div>

                        <div className="space-y-4 pt-4 border-t mt-4">
                             <h3 className="text-sm font-semibold text-muted-foreground flex items-center gap-2">
                                <Shield className="h-4 w-4" />
                                Comportamento e Lógica
                            </h3>

                            <div className="grid gap-3">
                                <div className="flex items-center gap-3 rounded-lg border p-3 hover:bg-muted/30 transition-colors">
                                    <Switch
                                        checked={stepSecret}
                                        onCheckedChange={setStepSecret}
                                    />
                                    <div className="space-y-0.5">
                                        <Label>Secret Step?</Label>
                                        <p className="text-xs text-muted-foreground">
                                            Se ativo, o estudante não verá as perguntas deste step.
                                        </p>
                                    </div>
                                </div>

                                <div className="flex items-center gap-3 rounded-lg border p-3 hover:bg-muted/30 transition-colors">
                                    <Switch
                                        checked={stepIsIterable}
                                        onCheckedChange={setStepIsIterable}
                                    />
                                    <div className="space-y-0.5">
                                        <Label>Step Iterável?</Label>
                                        <p className="text-xs text-muted-foreground">
                                            Permite que o usuário preencha este bloco múltiplas vezes.
                                        </p>
                                    </div>
                                </div>

                                {stepIsIterable && (
                                    <div className="ml-6 space-y-2 border-l-2 border-primary/20 pl-4 animate-in slide-in-from-left-2 fade-in duration-200">
                                        <Label>Limite de repetições (opcional)</Label>
                                        <Input
                                            type="number"
                                            placeholder="Ex: 5"
                                            value={stepRepeatLimit || ""}
                                            onChange={(e) => setStepRepeatLimit(parseInt(e.target.value) || null)}
                                        />
                                    </div>
                                )}

                                <div className="space-y-3">
                                    <div className="flex items-center gap-3 rounded-lg border p-3 hover:bg-muted/30 transition-colors">
                                        <Switch
                                            checked={stepHasCondition}
                                            onCheckedChange={setStepHasCondition}
                                        />
                                        <div className="space-y-0.5">
                                            <Label>Exibição Condicional?</Label>
                                            <p className="text-xs text-muted-foreground">
                                                Define se este step deve aparecer apenas sob certas condições.
                                            </p>
                                        </div>
                                    </div>
                                    
                                    {stepHasCondition && (
                                        <div className="ml-6 space-y-3 bg-muted/50 p-4 rounded-lg border border-dashed animate-in slide-in-from-left-2 fade-in duration-200">
                                            <div className="space-y-1.5">
                                                <Label className="text-xs font-semibold">Se a pergunta:</Label>
                                                <Select value={stepTriggerField} onValueChange={setStepTriggerField}>
                                                    <SelectTrigger className="bg-background">
                                                        <SelectValue placeholder="Selecione uma pergunta..." />
                                                    </SelectTrigger>
                                                    <SelectContent>
                                                        {fields
                                                            .filter(f => {
                                                                const triggerStep = steps.find(s => s.id === f.step_id);
                                                                return triggerStep && triggerStep.sort_order < stepSortOrder;
                                                            })
                                                            .map(f => (
                                                                <SelectItem key={f.id} value={f.field_name}>
                                                                    {f.question_text} ({f.field_name})
                                                                </SelectItem>
                                                            ))}
                                                    </SelectContent>
                                                </Select>
                                            </div>

                                            <div className="grid grid-cols-[1fr,2fr] gap-2">
                                                <div className="space-y-1.5">
                                                    <Label className="text-xs font-semibold">For:</Label>
                                                    <Select value={stepTriggerOperator} onValueChange={setStepTriggerOperator}>
                                                        <SelectTrigger className="bg-background">
                                                            <SelectValue />
                                                        </SelectTrigger>
                                                        <SelectContent>
                                                            <SelectItem value="==">Igual a</SelectItem>
                                                            <SelectItem value="!=">Diferente de</SelectItem>
                                                            <SelectItem value="in">Incluso em</SelectItem>
                                                        </SelectContent>
                                                    </Select>
                                                </div>
                                                <div className="space-y-1.5">
                                                    <Label className="text-xs font-semibold">Este Valor:</Label>
                                                    {(() => {
                                                        const triggerField = fields.find(f => f.field_name === stepTriggerField);
                                                        const options = triggerField?.options as string[] | null;
                                                        
                                                        if (options && options.length > 0 && (stepTriggerOperator === "==" || stepTriggerOperator === "!=")) {
                                                            return (
                                                                <Select value={stepTriggerValue} onValueChange={setStepTriggerValue}>
                                                                    <SelectTrigger className="bg-background">
                                                                        <SelectValue placeholder="Selecione o valor..." />
                                                                    </SelectTrigger>
                                                                    <SelectContent>
                                                                        {options.map((opt, i) => (
                                                                            <SelectItem key={i} value={opt}>{opt}</SelectItem>
                                                                        ))}
                                                                    </SelectContent>
                                                                </Select>
                                                            );
                                                        }

                                                        return (
                                                            <Input
                                                                className="bg-background"
                                                                value={stepTriggerValue}
                                                                onChange={(e) => setStepTriggerValue(e.target.value)}
                                                                placeholder="Valor esperado"
                                                            />
                                                        );
                                                    })()}
                                                </div>
                                            </div>
                                        </div>
                                    )}
                                </div>
                            </div>
                        </div>
                    </div>
                    <DialogFooter>
                        <Button variant="outline" onClick={() => setIsStepDialogOpen(false)}>Cancelar</Button>
                        <Button onClick={handleSaveStep} disabled={saveStepMutation.isPending}>
                            {saveStepMutation.isPending && <Loader2 className="h-4 w-4 animate-spin mr-2" />}
                            {editingStep ? "Salvar" : "Criar"}
                        </Button>
                    </DialogFooter>
                </DialogContent>
            </Dialog>

            {/* Add/Edit Field Dialog */}
            <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
                <DialogContent className="max-w-3xl max-h-[90vh] overflow-y-auto">
                    <DialogHeader>
                        <DialogTitle>
                            {editingField ? "Editar Campo" : "Novo Campo"}
                        </DialogTitle>
                    </DialogHeader>
                    <div className="space-y-4 py-2">
                        {/* Passo/Step Selection */}
                        <div className="space-y-2">
                            <Label>Etapa / Step (Opcional)</Label>
                            <Select
                                value={formValues.step_id}
                                onValueChange={(val) => setFormValues(prev => ({ ...prev, step_id: val === "none" ? "" : val }))}
                            >
                                <SelectTrigger>
                                    <SelectValue placeholder="Selecione um passo..." />
                                </SelectTrigger>
                                <SelectContent>
                                    <SelectItem value="none">Sem Passo Assinado</SelectItem>
                                    {steps.map((st) => (
                                        <SelectItem key={st.id} value={st.id}>
                                            {st.step_name}
                                        </SelectItem>
                                    ))}
                                </SelectContent>
                            </Select>
                        </div>

                        <div className="grid grid-cols-2 gap-4">
                            <div className="space-y-2">
                                <Label>Nome do Campo (key)</Label>
                                <Input
                                    placeholder="ex: whatsapp, renda"
                                    value={formValues.field_name}
                                    onChange={(e) => setFormValues({ ...formValues, field_name: e.target.value })}
                                />
                            </div>
                            <div className="space-y-2">
                                <Label>Ordem dentro do formulário</Label>
                                <Input
                                    type="number"
                                    value={formValues.sort_order}
                                    onChange={(e) => setFormValues({ ...formValues, sort_order: parseInt(e.target.value) || 0 })}
                                />
                            </div>
                        </div>

                        <div className="space-y-2">
                            <Label>Texto da Pergunta</Label>
                            <Input
                                placeholder="ex: Qual seu número de WhatsApp?"
                                value={formValues.question_text}
                                onChange={(e) => setFormValues({ ...formValues, question_text: e.target.value })}
                            />
                        </div>

                        <div className="grid grid-cols-3 gap-4">
                            <div className="space-y-2">
                                <Label>Tipo de Dado</Label>
                                <Select
                                    value={formValues.data_type}
                                    onValueChange={(val) => {
                                        // Reset mask if incompatible with new data type
                                        let newMask = formValues.maskking;
                                        if (val === "text") {
                                            if (!MASK_TYPES_TEXT.find(m => m.value === newMask)) newMask = "none";
                                        } else if (val === "number") {
                                            if (!MASK_TYPES_NUMBER.find(m => m.value === newMask)) newMask = "none";
                                        } else {
                                            newMask = "none";
                                        }
                                        setFormValues({ ...formValues, data_type: val, maskking: newMask });
                                    }}
                                >
                                    <SelectTrigger>
                                        <SelectValue />
                                    </SelectTrigger>
                                    <SelectContent>
                                        {DATA_TYPES.map((dt) => (
                                            <SelectItem key={dt.value} value={dt.value}>
                                                {dt.label}
                                            </SelectItem>
                                        ))}
                                    </SelectContent>
                                </Select>
                            </div>
                            <div className="space-y-2">
                                <Label>Componente UI Especial (opcional)</Label>
                                <p className="text-xs text-muted-foreground">
                                    Substitui o campo de resposta por um componente interativo específico.
                                </p>
                                <Select
                                    value={formValues.ui_component || "__none__"}
                                    onValueChange={(val) =>
                                        setFormValues({ ...formValues, ui_component: val === "__none__" ? "" : val })
                                    }
                                >
                                    <SelectTrigger>
                                        <SelectValue placeholder="Nenhum (campo padrão)" />
                                    </SelectTrigger>
                                    <SelectContent>
                                        <SelectItem value="__none__">
                                            <div className="flex flex-col">
                                                <span className="font-medium">Nenhum</span>
                                                <span className="text-xs text-muted-foreground">Campo de resposta padrão</span>
                                            </div>
                                        </SelectItem>
                                        <SelectItem value="income_calculator">
                                            <div className="flex flex-col">
                                                <span className="font-medium">🧮 Calculadora de Renda</span>
                                                <span className="text-xs text-muted-foreground">Calcula renda per capita por nº de membros e rendas individuais</span>
                                            </div>
                                        </SelectItem>
                                    </SelectContent>
                                </Select>
                                {formValues.ui_component && formValues.ui_component !== "" && (
                                    <div className="flex items-center gap-2 p-2 bg-blue-50 border border-blue-200 rounded-lg text-xs text-blue-700">
                                        <span className="font-mono bg-blue-100 px-1.5 py-0.5 rounded">{formValues.ui_component}</span>
                                        <span>será usado no lugar do campo padrão</span>
                                    </div>
                                )}
                            </div>
                            <div className="space-y-2 flex flex-col">
                                <Label>Auto-Fill (mapping)</Label>
                                <Popover open={mappingOpen} onOpenChange={setMappingOpen}>
                                    <PopoverTrigger asChild>
                                        <Button
                                            variant="outline"
                                            role="combobox"
                                            aria-expanded={mappingOpen}
                                            className="w-full justify-between font-normal"
                                        >
                                            {formValues.mapping_source
                                                ? getMappingLabel(formValues.mapping_source)
                                                : "Nenhum (perguntar sempre)"}
                                            <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
                                        </Button>
                                    </PopoverTrigger>
                                    <PopoverContent className="w-full p-0" align="start">
                                        <Command>
                                            <CommandInput placeholder="Buscar mapeamento..." />
                                            <CommandList 
                                                className="max-h-[300px] overflow-y-auto"
                                                onWheel={(e) => {
                                                    // Ensure mouse wheel scroll works inside the popover
                                                    e.currentTarget.scrollTop += e.deltaY;
                                                }}
                                            >
                                                <CommandEmpty>Nenhum mapeamento encontrado.</CommandEmpty>
                                                <CommandGroup>
                                                    {mappingSources.map((ms) => (
                                                        <CommandItem
                                                            key={ms.value || "_none"}
                                                            value={ms.label}
                                                            onSelect={() => {
                                                                setFormValues({ ...formValues, mapping_source: ms.value });
                                                                setMappingOpen(false);
                                                            }}
                                                        >
                                                            <Check
                                                                className={cn(
                                                                    "mr-2 h-4 w-4",
                                                                    formValues.mapping_source === ms.value ? "opacity-100" : "opacity-0"
                                                                )}
                                                            />
                                                            {ms.label}
                                                        </CommandItem>
                                                    ))}
                                                </CommandGroup>
                                            </CommandList>
                                        </Command>
                                    </PopoverContent>
                                </Popover>
                            </div>
                        </div>

                        {(formValues.data_type === "text" || formValues.data_type === "number") && (
                            <div className="space-y-2">
                                <Label>Máscara / Validação</Label>
                                <Select
                                    value={formValues.maskking || "none"}
                                    onValueChange={(val) => setFormValues({ ...formValues, maskking: val === "none" ? "" : val })}
                                >
                                    <SelectTrigger>
                                        <SelectValue placeholder="Selecione uma máscara..." />
                                    </SelectTrigger>
                                    <SelectContent>
                                        {(formValues.data_type === "text" ? MASK_TYPES_TEXT : MASK_TYPES_NUMBER).map((mt) => (
                                            <SelectItem key={mt.value} value={mt.value}>
                                                {mt.label}
                                            </SelectItem>
                                        ))}
                                    </SelectContent>
                                </Select>
                            </div>
                        )}

                        {(formValues.data_type === "select" || formValues.data_type === "multiselect" || formValues.data_type === "searchable_select") && (
                            <div className="space-y-3 bg-muted/50 p-4 rounded-md border">
                                <div className="flex items-center justify-between">
                                    <Label className="flex items-center gap-2">
                                        <Code2 className="h-4 w-4" />
                                        Opções de Escolha
                                    </Label>
                                    <div className="flex gap-2">
                                        <Button
                                            variant="outline"
                                            size="sm"
                                            className="gap-1.5 h-7 text-xs"
                                            onClick={handleImportOptions}
                                        >
                                            <Upload className="h-3.5 w-3.5" />
                                            Importar
                                        </Button>
                                        <Button
                                            variant="outline"
                                            size="sm"
                                            className="gap-1.5 h-7 text-xs text-red-600 hover:text-red-700 hover:bg-red-50"
                                            onClick={() => setFormValues({ ...formValues, optionsList: [""] })}
                                        >
                                            <Trash2 className="h-3.5 w-3.5" />
                                            Limpar
                                        </Button>
                                    </div>
                                </div>
                                <div className={cn("space-y-2", formValues.optionsList.length > 10 && "max-h-[320px] overflow-y-auto pr-1")}>
                                    {formValues.optionsList.map((opt, i) => (
                                        <div key={i} className="flex gap-2 items-center">
                                            <Input
                                                value={opt}
                                                onChange={(e) => updateOption(i, e.target.value)}
                                                placeholder={`Opção ${i + 1}`}
                                                className="bg-background"
                                            />
                                            <Button
                                                variant="ghost"
                                                size="icon"
                                                onClick={() => removeOption(i)}
                                                disabled={formValues.optionsList.length <= 1}
                                            >
                                                <X className="h-4 w-4 text-muted-foreground" />
                                            </Button>
                                        </div>
                                    ))}
                                </div>
                                <div className="flex gap-2 mt-2">
                                    <Button
                                        variant="outline"
                                        size="sm"
                                        className="flex-1 border-dashed"
                                        onClick={addOption}
                                    >
                                        <Plus className="h-4 w-4 mr-2" />
                                        Adicionar Opção
                                    </Button>
                                    {formValues.mapping_source && (
                                        <Button
                                            variant="secondary"
                                            size="sm"
                                            className="flex-1 gap-2"
                                            onClick={loadOptionsFromDB}
                                            disabled={isLoadingOptions}
                                        >
                                            {isLoadingOptions ? (
                                                <Loader2 className="h-4 w-4 animate-spin" />
                                            ) : (
                                                <Download className="h-4 w-4" />
                                            )}
                                            Carregar do banco
                                        </Button>
                                    )}
                                </div>
                            </div>
                        )}

                        {(formValues.data_type === "grid_select" || formValues.data_type === "grid_multiselect") && (
                            <div className="space-y-4 bg-muted/50 p-4 rounded-md border">
                                <div className="flex items-center gap-2">
                                    <Grid3X3 className="h-4 w-4" />
                                    <Label>Configuração da Grade</Label>
                                    <Badge variant="outline" className="text-[10px]">
                                        {formValues.data_type === "grid_select" ? "1 resposta por linha" : "Múltiplas respostas por linha"}
                                    </Badge>
                                </div>

                                <div className="grid grid-cols-2 gap-4">
                                    {/* Linhas */}
                                    <div className="space-y-2">
                                        <Label className="text-xs font-semibold text-muted-foreground">Linhas (afirmações/itens)</Label>
                                        <div className={cn("space-y-2", formValues.gridRows.length > 8 && "max-h-[280px] overflow-y-auto pr-1")}>
                                            {formValues.gridRows.map((row, i) => (
                                                <div key={i} className="flex gap-1.5 items-center">
                                                    <span className="text-xs text-muted-foreground w-5 shrink-0">{i + 1}.</span>
                                                    <Input
                                                        value={row}
                                                        onChange={(e) => {
                                                            const newRows = [...formValues.gridRows];
                                                            newRows[i] = e.target.value;
                                                            setFormValues({ ...formValues, gridRows: newRows });
                                                        }}
                                                        placeholder={`Linha ${i + 1}`}
                                                        className="bg-background h-8 text-sm"
                                                    />
                                                    <Button
                                                        variant="ghost"
                                                        size="icon"
                                                        className="h-7 w-7 shrink-0"
                                                        onClick={() => {
                                                            const newRows = formValues.gridRows.filter((_, idx) => idx !== i);
                                                            setFormValues({ ...formValues, gridRows: newRows });
                                                        }}
                                                        disabled={formValues.gridRows.length <= 1}
                                                    >
                                                        <X className="h-3.5 w-3.5 text-muted-foreground" />
                                                    </Button>
                                                </div>
                                            ))}
                                        </div>
                                        <Button
                                            variant="outline"
                                            size="sm"
                                            className="w-full border-dashed h-7 text-xs"
                                            onClick={() => setFormValues({ ...formValues, gridRows: [...formValues.gridRows, ""] })}
                                        >
                                            <Plus className="h-3.5 w-3.5 mr-1" />
                                            Adicionar linha
                                        </Button>
                                    </div>

                                    {/* Colunas */}
                                    <div className="space-y-2">
                                        <Label className="text-xs font-semibold text-muted-foreground">Colunas (opções de resposta)</Label>
                                        <div className={cn("space-y-2", formValues.gridColumns.length > 8 && "max-h-[280px] overflow-y-auto pr-1")}>
                                            {formValues.gridColumns.map((col, i) => (
                                                <div key={i} className="flex gap-1.5 items-center">
                                                    <Input
                                                        value={col}
                                                        onChange={(e) => {
                                                            const newCols = [...formValues.gridColumns];
                                                            newCols[i] = e.target.value;
                                                            setFormValues({ ...formValues, gridColumns: newCols });
                                                        }}
                                                        placeholder={`Coluna ${i + 1}`}
                                                        className="bg-background h-8 text-sm"
                                                    />
                                                    <Button
                                                        variant="ghost"
                                                        size="icon"
                                                        className="h-7 w-7 shrink-0"
                                                        onClick={() => {
                                                            const newCols = formValues.gridColumns.filter((_, idx) => idx !== i);
                                                            setFormValues({ ...formValues, gridColumns: newCols });
                                                        }}
                                                        disabled={formValues.gridColumns.length <= 1}
                                                    >
                                                        <X className="h-3.5 w-3.5 text-muted-foreground" />
                                                    </Button>
                                                </div>
                                            ))}
                                        </div>
                                        <Button
                                            variant="outline"
                                            size="sm"
                                            className="w-full border-dashed h-7 text-xs"
                                            onClick={() => setFormValues({ ...formValues, gridColumns: [...formValues.gridColumns, ""] })}
                                        >
                                            <Plus className="h-3.5 w-3.5 mr-1" />
                                            Adicionar coluna
                                        </Button>
                                    </div>
                                </div>

                                {/* Preview */}
                                {formValues.gridRows.filter(r => r.trim()).length > 0 && formValues.gridColumns.filter(c => c.trim()).length > 0 && (
                                    <div className="mt-3 pt-3 border-t">
                                        <Label className="text-xs text-muted-foreground mb-2 block">Pré-visualização</Label>
                                        <div className="rounded-md border overflow-auto max-h-[200px]">
                                            <Table>
                                                <TableHeader>
                                                    <TableRow>
                                                        <TableHead className="text-xs min-w-[150px]"></TableHead>
                                                        {formValues.gridColumns.filter(c => c.trim()).map((col, i) => (
                                                            <TableHead key={i} className="text-xs text-center min-w-[80px]">{col}</TableHead>
                                                        ))}
                                                    </TableRow>
                                                </TableHeader>
                                                <TableBody>
                                                    {formValues.gridRows.filter(r => r.trim()).map((row, i) => (
                                                        <TableRow key={i}>
                                                            <TableCell className="text-xs font-medium">{row}</TableCell>
                                                            {formValues.gridColumns.filter(c => c.trim()).map((_, j) => (
                                                                <TableCell key={j} className="text-center">
                                                                    {formValues.data_type === "grid_select" ? (
                                                                        <div className="h-4 w-4 rounded-full border-2 border-muted-foreground/30 mx-auto" />
                                                                    ) : (
                                                                        <div className="h-4 w-4 rounded border-2 border-muted-foreground/30 mx-auto" />
                                                                    )}
                                                                </TableCell>
                                                            ))}
                                                        </TableRow>
                                                    ))}
                                                </TableBody>
                                            </Table>
                                        </div>
                                    </div>
                                )}
                            </div>
                        )}

                        <div className="space-y-4 pt-4 border-t mt-4">
                            <h3 className="text-sm font-semibold text-muted-foreground flex items-center gap-2">
                                <Shield className="h-4 w-4" />
                                Comportamento e Lógica
                            </h3>
                            
                            <div className="grid gap-3">
                                {/* Opcional? */}
                                <div className="flex items-center gap-3 rounded-lg border p-3 hover:bg-muted/30 transition-colors">
                                    <Switch
                                        checked={formValues.optional}
                                        onCheckedChange={(val) => setFormValues({ ...formValues, optional: val })}
                                    />
                                    <div className="space-y-0.5">
                                        <Label>Este campo é opcional?</Label>
                                        <p className="text-xs text-muted-foreground">
                                            Se sim, o estudante poderá pular esta pergunta.
                                        </p>
                                    </div>
                                </div>

                                {/* Exibição Condicional? */}
                                <div className="space-y-3">
                                    <div className="flex items-center gap-3 rounded-lg border p-3 hover:bg-muted/30 transition-colors">
                                        <Switch
                                            checked={fieldHasCondition}
                                            onCheckedChange={setFieldHasCondition}
                                        />
                                        <div className="space-y-0.5">
                                            <Label>Exibição Condicional?</Label>
                                            <p className="text-xs text-muted-foreground">
                                                Define se este campo deve aparecer apenas sob certas condições.
                                            </p>
                                        </div>
                                    </div>

                                    {fieldHasCondition && (
                                        <div className="ml-6 space-y-3 bg-muted/50 p-4 rounded-lg border border-dashed animate-in slide-in-from-left-2 fade-in duration-200">
                                            <div className="space-y-1.5">
                                                <Label className="text-xs font-semibold">Se a pergunta:</Label>
                                                <Select value={fieldTriggerField} onValueChange={setFieldTriggerField}>
                                                    <SelectTrigger className="bg-background">
                                                        <SelectValue placeholder="Selecione uma pergunta..." />
                                                    </SelectTrigger>
                                                    <SelectContent>
                                                        {/* Opção especial para iteração se o step for iterável */}
                                                        {(() => {
                                                            const currentStepObj = steps.find(s => s.id === formValues.step_id);
                                                            if (currentStepObj?.is_iterable) {
                                                                return (
                                                                    <SelectItem value="_iteration_index">
                                                                        🔄 Iteração do Bloco (Atual)
                                                                    </SelectItem>
                                                                );
                                                            }
                                                            return null;
                                                        })()}
                                                        {fields
                                                            .filter(f => {
                                                                const currentStepObj = steps.find(s => s.id === formValues.step_id);
                                                                const triggerStepObj = steps.find(s => s.id === f.step_id);
                                                                
                                                                if (!currentStepObj || !triggerStepObj) return false;
                                                                
                                                                if (triggerStepObj.sort_order < currentStepObj.sort_order) return true;
                                                                if (f.step_id === formValues.step_id && f.sort_order < formValues.sort_order) return true;
                                                                
                                                                return false;
                                                            })
                                                            .map(f => (
                                                                <SelectItem key={f.id} value={f.field_name}>
                                                                    {f.question_text} ({f.field_name})
                                                                </SelectItem>
                                                            ))}
                                                    </SelectContent>
                                                </Select>
                                            </div>

                                            <div className="grid grid-cols-[1fr,2fr] gap-2">
                                                <div className="space-y-1.5">
                                                    <Label className="text-xs font-semibold">For:</Label>
                                                    <Select value={fieldTriggerOperator} onValueChange={setFieldTriggerOperator}>
                                                        <SelectTrigger className="bg-background">
                                                            <SelectValue />
                                                        </SelectTrigger>
                                                        <SelectContent>
                                                            <SelectItem value="==">Igual a</SelectItem>
                                                            <SelectItem value="!=">Diferente de</SelectItem>
                                                            <SelectItem value="in">Incluso em</SelectItem>
                                                        </SelectContent>
                                                    </Select>
                                                </div>
                                                <div className="space-y-1.5">
                                                    <Label className="text-xs font-semibold">Este Valor:</Label>
                                                    {(() => {
                                                        if (fieldTriggerField === "_iteration_index") {
                                                            return (
                                                                <Select value={fieldTriggerValue} onValueChange={setFieldTriggerValue}>
                                                                    <SelectTrigger className="bg-background">
                                                                        <SelectValue placeholder="Selecione..." />
                                                                    </SelectTrigger>
                                                                    <SelectContent>
                                                                        <SelectItem value="0">Primeira iteração (index 0)</SelectItem>
                                                                    </SelectContent>
                                                                </Select>
                                                            );
                                                        }

                                                        const triggerField = fields.find(f => f.field_name === fieldTriggerField);
                                                        const options = triggerField?.options as string[] | null;
                                                        
                                                        if (options && options.length > 0 && (fieldTriggerOperator === "==" || fieldTriggerOperator === "!=")) {
                                                            return (
                                                                <Select value={fieldTriggerValue} onValueChange={setFieldTriggerValue}>
                                                                    <SelectTrigger className="bg-background">
                                                                        <SelectValue placeholder="Selecione o valor..." />
                                                                    </SelectTrigger>
                                                                    <SelectContent>
                                                                        {options.map((opt, i) => (
                                                                            <SelectItem key={i} value={opt}>{opt}</SelectItem>
                                                                        ))}
                                                                    </SelectContent>
                                                                </Select>
                                                            );
                                                        }

                                                        return (
                                                            <Input
                                                                className="bg-background"
                                                                value={fieldTriggerValue}
                                                                onChange={(e) => setFieldTriggerValue(e.target.value)}
                                                                placeholder="Valor esperado"
                                                            />
                                                        );
                                                    })()}
                                                </div>
                                            </div>
                                        </div>
                                    )}
                                </div>

                                {/* Critério? */}
                                <div className="space-y-3">
                                    <div className="flex items-center gap-3 rounded-lg border p-3 hover:bg-muted/30 transition-colors">
                                        <Switch
                                            checked={formValues.is_criterion}
                                            onCheckedChange={(val) => setFormValues({ ...formValues, is_criterion: val })}
                                        />
                                        <div className="space-y-0.5">
                                            <Label>Critério de Seleção?</Label>
                                            <p className="text-xs text-muted-foreground">
                                                Se sim, a resposta será avaliada para determinar a aprovação.
                                            </p>
                                        </div>
                                    </div>

                                    {formValues.is_criterion && (
                                        <div className="ml-6 space-y-3 animate-in slide-in-from-left-2 fade-in duration-200">
                                            <div>
                                                <Label className="text-sm">Tipo de Critério</Label>
                                                <select
                                                    value={formValues.criterion_type}
                                                    onChange={(e) => setFormValues({ ...formValues, criterion_type: e.target.value as 'eligibility' | 'priority' })}
                                                    className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                                                >
                                                    <option value="eligibility">Elegibilidade (eliminatório)</option>
                                                    <option value="priority">Priorização (preferencial)</option>
                                                </select>
                                                <p className="text-xs text-muted-foreground mt-1">
                                                    {formValues.criterion_type === 'eligibility'
                                                        ? 'Candidato que não atender será considerado inelegível.'
                                                        : 'Candidato que atender terá prioridade, mas não será eliminado.'}
                                                </p>
                                            </div>
                                            <CriterionRuleBuilder
                                                fieldName={formValues.field_name}
                                                value={formValues.criterion_rule}
                                                onChange={(jsonStr) => setFormValues({ ...formValues, criterion_rule: jsonStr })}
                                                dataType={formValues.data_type}
                                                optionsList={formValues.optionsList}
                                                label={formValues.criterion_type === 'priority' ? 'Regra de Priorização' : 'Regra de Elegibilidade'}
                                            />
                                        </div>
                                    )}
                                </div>
                            </div>
                        </div>
                    </div>
                    <DialogFooter>
                        <Button variant="outline" onClick={() => setIsDialogOpen(false)}>Cancelar</Button>
                        <Button onClick={handleSave} disabled={saveMutation.isPending}>
                            {saveMutation.isPending ? <Loader2 className="h-4 w-4 animate-spin mr-2" /> : null}
                            {editingField ? "Salvar" : "Criar"}
                        </Button>
                    </DialogFooter>
                </DialogContent>
            </Dialog>

            {/* Delete Field Confirmation */}
            <AlertDialog open={!!deleteFieldId} onOpenChange={() => setDeleteFieldId(null)}>
                <AlertDialogContent>
                    <AlertDialogHeader>
                        <AlertDialogTitle>Remover campo?</AlertDialogTitle>
                        <AlertDialogDescription>
                            Esta ação não pode ser desfeita. O campo será removido permanentemente do formulário.
                        </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                        <AlertDialogCancel>Cancelar</AlertDialogCancel>
                        <AlertDialogAction
                            onClick={() => deleteFieldId && deleteMutation.mutate(deleteFieldId)}
                            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                        >
                            Remover
                        </AlertDialogAction>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialog>

            {/* Delete Step Confirmation */}
            <AlertDialog open={!!deleteStepId} onOpenChange={() => setDeleteStepId(null)}>
                <AlertDialogContent>
                    <AlertDialogHeader>
                        <AlertDialogTitle>Remover Step?</AlertDialogTitle>
                        <AlertDialogDescription>
                            Tem certeza? Isso apagará o Step. Lembre-se que campos associados a este step ficarão órfãos.
                        </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                        <AlertDialogCancel>Cancelar</AlertDialogCancel>
                        <AlertDialogAction
                            onClick={() => deleteStepId && deleteStepMutation.mutate(deleteStepId)}
                            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                        >
                            Remover
                        </AlertDialogAction>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialog>

            {/* Import Fields Dialog */}
            <Dialog open={isImportFieldsDialogOpen} onOpenChange={setIsImportFieldsDialogOpen}>
                <DialogContent className="max-w-md">
                    <DialogHeader>
                        <DialogTitle>Importar campos de outra etapa</DialogTitle>
                    </DialogHeader>
                    <div className="space-y-4 py-4">
                        <div className="space-y-2">
                            <Label>Oportunidade de Origem</Label>
                            <Select value={importSourcePartnerId} onValueChange={setImportSourcePartnerId}>
                                <SelectTrigger>
                                    <SelectValue placeholder="Selecione a oportunidade..." />
                                </SelectTrigger>
                                <SelectContent>
                                    {opportunities.map((opp) => (
                                        <SelectItem key={opp.id} value={opp.id}>
                                            {opp.name}
                                        </SelectItem>
                                    ))}
                                </SelectContent>
                            </Select>
                        </div>

                        <div className="space-y-2">
                            <Label>Etapa de Origem</Label>
                            <Select value={importSourceStepId} onValueChange={setImportSourceStepId} disabled={!importSourcePartnerId || isLoadingImportSteps}>
                                <SelectTrigger>
                                    <SelectValue placeholder={isLoadingImportSteps ? "Carregando..." : "Selecione a etapa..."} />
                                </SelectTrigger>
                                <SelectContent>
                                    {importSourceSteps.map((s) => (
                                        <SelectItem key={s.id} value={s.id}>
                                            {s.sort_order}. {s.step_name}
                                        </SelectItem>
                                    ))}
                                    {importSourceSteps.length === 0 && !isLoadingImportSteps && importSourcePartnerId && (
                                        <div className="p-2 text-xs text-muted-foreground text-center">Nenhuma etapa encontrada.</div>
                                    )}
                                </SelectContent>
                            </Select>
                        </div>
                    </div>
                    <DialogFooter>
                        <Button variant="outline" onClick={() => setIsImportFieldsDialogOpen(false)}>Cancelar</Button>
                        <Button
                            onClick={handleImportFields}
                            disabled={!importSourceStepId || isImporting}
                        >
                            {isImporting ? (
                                <>
                                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                                    Importando...
                                </>
                            ) : "Importar Agora"}
                        </Button>
                    </DialogFooter>
                </DialogContent>
            </Dialog>

            {/* Individual Field Clone Dialog */}
            <Dialog open={isCloneFieldDialogOpen} onOpenChange={setIsCloneFieldDialogOpen}>
                <DialogContent className="max-w-md">
                    <DialogHeader>
                        <DialogTitle>Clonar Pergunta</DialogTitle>
                    </DialogHeader>
                    {cloningFieldSource && (
                        <div className="p-3 bg-muted rounded-md text-sm mb-2 border border-dashed">
                             <div className="font-semibold text-xs text-muted-foreground mb-1 uppercase tracking-wider">Pergunta:</div>
                             {cloningFieldSource.question_text}
                        </div>
                    )}
                    <div className="space-y-4 py-4">
                        <div className="space-y-2">
                            <Label>Oportunidade de Destino</Label>
                            <Select value={cloneFieldTargetPartnerId} onValueChange={setCloneFieldTargetPartnerId}>
                                <SelectTrigger>
                                    <SelectValue placeholder="Selecione a oportunidade..." />
                                </SelectTrigger>
                                <SelectContent>
                                    {opportunities.map((opp) => (
                                        <SelectItem key={opp.id} value={opp.id}>
                                            {opp.name}
                                        </SelectItem>
                                    ))}
                                </SelectContent>
                            </Select>
                        </div>

                        <div className="space-y-2">
                            <Label>Etapa de Destino</Label>
                            <Select value={cloneFieldTargetStepId} onValueChange={setCloneFieldTargetStepId} disabled={!cloneFieldTargetPartnerId || isLoadingCloneTargetSteps}>
                                <SelectTrigger>
                                    <SelectValue placeholder={isLoadingCloneTargetSteps ? "Carregando..." : "Selecione a etapa..."} />
                                </SelectTrigger>
                                <SelectContent>
                                    <SelectItem value="orphan">Sem Step (Órfão)</SelectItem>
                                    {cloneTargetSteps.map((s) => (
                                        <SelectItem key={s.id} value={s.id}>
                                            {s.sort_order}. {s.step_name}
                                        </SelectItem>
                                    ))}
                                </SelectContent>
                            </Select>
                        </div>
                    </div>
                    <DialogFooter>
                        <Button variant="outline" onClick={() => setIsCloneFieldDialogOpen(false)}>Cancelar</Button>
                        <Button
                            onClick={handleCloneSingleField}
                            disabled={!cloneFieldTargetStepId || isCloningSingle}
                        >
                            {isCloningSingle ? (
                                <>
                                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                                    Clonando...
                                </>
                            ) : "Confirmar Clone"}
                        </Button>
                    </DialogFooter>
                </DialogContent>
            </Dialog>
        </div>
    );
}
