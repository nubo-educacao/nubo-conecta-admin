import { useMemo, useState, useEffect } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import {
    Search,
    CheckCircle2,
    XCircle,
    Clock,
    FileSpreadsheet,
    Eye,
    ExternalLink,
} from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import type { ApplicationWithDetails, PartnerOption, OpportunityPhase } from "@/services/applicationsService";
import { getPartnerFormFieldsMap } from "@/services/applicationsService";
import { calculateApplicationProgress } from "@/utils/calculateApplicationProgress";
import { Checkbox } from "@/components/ui/checkbox";
import { Plus } from "lucide-react";

// ─── Status helpers ──────────────────────────────────────────────────────────

const STATUS_CONFIG: Record<
    string,
    { label: string; variant: "default" | "secondary" | "destructive" | "outline"; icon: React.ElementType }
> = {
    DRAFT: { label: "Rascunho", variant: "outline", icon: Clock },
    SUBMITTED: { label: "Enviado", variant: "secondary", icon: FileSpreadsheet },
    redirected: { label: "Redirecionado", variant: "default", icon: ExternalLink },
};

function StatusBadge({ status }: { status: string }) {
    const config = STATUS_CONFIG[status] || { label: status, variant: "outline" as const, icon: Clock };
    const Icon = config.icon;
    return (
        <Badge variant={config.variant} className="flex items-center gap-1 whitespace-nowrap">
            <Icon className="h-3 w-3" />
            {config.label}
        </Badge>
    );
}

// ─── Phone formatter ─────────────────────────────────────────────────────────

function formatPhone(phone: string | null): string {
    if (!phone) return "—";
    const digits = phone.replace(/\D/g, "");
    if (digits.length === 13) {
        return `+${digits.slice(0, 2)} (${digits.slice(2, 4)}) ${digits.slice(4, 9)}-${digits.slice(9)}`;
    }
    if (digits.length === 12) {
        return `+${digits.slice(0, 2)} (${digits.slice(2, 4)}) ${digits.slice(4, 8)}-${digits.slice(8)}`;
    }
    if (digits.length === 11) {
        return `(${digits.slice(0, 2)}) ${digits.slice(2, 7)}-${digits.slice(7)}`;
    }
    return phone;
}

// ─── Props ───────────────────────────────────────────────────────────────────

interface ApplicationsTableProps {
    applications: ApplicationWithDetails[];
    isLoading: boolean;
    onViewAnswers: (app: ApplicationWithDetails) => void;
    /**
     * Oportunidade filter dropdown + column (partner_opportunities).
     * Controlled mode (server-side refetch): pass partnerFilter + onPartnerFilterChange.
     * Uncontrolled mode (client-side filter): pass only `partners`, omit the callback —
     * used by the partner portal, where applications are already scoped to 1 institution.
     */
    partners?: PartnerOption[];
    partnerFilter?: string;
    onPartnerFilterChange?: (value: string) => void;
    /**
     * Parceiro (institution) filter dropdown + column (ADR-0014). Admin-only —
     * omitted in the partner portal, where the view is already scoped to 1 partner.
     * Always client-side (institution_id already present on each application row).
     */
    institutions?: PartnerOption[];
    onFilteredDataChange?: (applications: ApplicationWithDetails[]) => void;
    // Props for Opportunity Phases — also powers the Fase filter dropdown (ADR-0014)
    phases?: OpportunityPhase[];
    onPhaseChange?: (appId: string, phaseId: string | null) => void;
    onBulkPhaseChange?: (appIds: string[], phaseId: string | null) => void;
}

// ─── Eligibility formatter ─────────────────────────────────────────────────────

function EligibilityCell({ app }: { app: ApplicationWithDetails }) {
    const eligibilityResults = app.eligibility_results;
    if (!eligibilityResults || !Array.isArray(eligibilityResults) || eligibilityResults.length === 0) {
        return <span className="text-muted-foreground">—</span>;
    }
    
    const isGrouped = eligibilityResults.length > 0 && 'partner_id' in eligibilityResults[0];
    
    if (isGrouped) {
        // Find the eligibility object for this partner
        const resultForPartner = eligibilityResults.find((r: any) => r.partner_id === app.partner_id);
        
        if (!resultForPartner) {
            return <span className="text-muted-foreground">—</span>;
        }

        const total = resultForPartner.total_criteria || 0;
        const met = resultForPartner.met_criteria || 0;
        
        if (total === 0) {
             return <span className="text-muted-foreground">—</span>;
        }
        
        const isEligible = met === total;
        return (
            <div className="flex items-center gap-2 whitespace-nowrap">
                <span className="font-medium" title={isEligible ? "Totalmente elegível" : "Parcialmente elegível"}>{met} / {total}</span>
                {isEligible && <CheckCircle2 className="h-4 w-4 text-green-500" />}
            </div>
        );
    } else {
        // Legacy flat format
        const total = eligibilityResults.length;
        const met = eligibilityResults.filter((r: any) => r.met === true).length;
        if (total === 0) {
            return <span className="text-muted-foreground">—</span>;
        }
        const isEligible = met === total;
        return (
            <div className="flex items-center gap-2 whitespace-nowrap">
                <span className="font-medium" title={isEligible ? "Totalmente elegível" : "Parcialmente elegível"}>{met} / {total}</span>
                {isEligible && <CheckCircle2 className="h-4 w-4 text-green-500" />}
            </div>
        );
    }
}

// ─── Component ───────────────────────────────────────────────────────────────

export default function ApplicationsTable({
    applications,
    isLoading,
    onViewAnswers,
    partners,
    partnerFilter,
    onPartnerFilterChange,
    institutions,
    onFilteredDataChange,
    phases = [],
    onPhaseChange,
    onBulkPhaseChange,
}: ApplicationsTableProps) {
    const showOpportunityColumn = !!partners;
    const showInstitutionColumn = !!institutions;
    const showPhaseColumn = phases.length > 0 || !!onPhaseChange;
    const showPhaseFilter = phases.length > 0;
    const [search, setSearch] = useState("");
    const [statusFilter, setStatusFilter] = useState<string>("all");
    const [institutionFilter, setInstitutionFilter] = useState<string>("all");
    const [phaseFilter, setPhaseFilter] = useState<string>("all");

    // Oportunidade filter: controlled (server-side refetch, admin) when
    // onPartnerFilterChange is provided; otherwise uncontrolled (client-side
    // filter over the already-fetched list), used by the partner portal.
    const [internalOpportunityFilter, setInternalOpportunityFilter] = useState<string>("all");
    const isOpportunityFilterControlled = !!onPartnerFilterChange;
    const opportunityFilterValue = isOpportunityFilterControlled ? (partnerFilter || "all") : internalOpportunityFilter;
    const handleOpportunityFilterChange = onPartnerFilterChange || setInternalOpportunityFilter;

    // Checkbox selections for bulk actions
    const [selectedIds, setSelectedIds] = useState<string[]>([]);

    const { data: formFieldsMap = {} } = useQuery({
        queryKey: ["partnerFormFieldsMap"],
        queryFn: getPartnerFormFieldsMap,
    });

    const filteredApplications = useMemo(() => {
        return applications.filter((app) => {
            if (statusFilter !== "all" && app.status !== statusFilter) return false;
            if (institutionFilter !== "all" && app.institution_id !== institutionFilter) return false;
            if (phaseFilter !== "all" && app.phase_id !== phaseFilter) return false;
            if (!isOpportunityFilterControlled && internalOpportunityFilter !== "all" && app.partner_id !== internalOpportunityFilter) return false;
            if (search) {
                const searchLower = search.toLowerCase();
                const nameMatch = app.full_name?.toLowerCase().includes(searchLower);
                if (!nameMatch) return false;
            }
            return true;
        });
    }, [applications, statusFilter, institutionFilter, phaseFilter, isOpportunityFilterControlled, internalOpportunityFilter, search]);

    // Reset selected IDs when applications list changes or filters apply
    useEffect(() => {
        setSelectedIds([]);
    }, [filteredApplications]);

    // Report filtered applications to parent
    useEffect(() => {
        if (onFilteredDataChange) {
            onFilteredDataChange(filteredApplications);
        }
    }, [filteredApplications, onFilteredDataChange]);

    // Toggle single selection
    const toggleSelect = (id: string) => {
        setSelectedIds(prev => 
            prev.includes(id) ? prev.filter(x => x !== id) : [...prev, id]
        );
    };

    // Toggle all selection
    const toggleSelectAll = () => {
        if (selectedIds.length === filteredApplications.length) {
            setSelectedIds([]);
        } else {
            setSelectedIds(filteredApplications.map(app => app.id));
        }
    };

    // Helper to get opportunity phases for a row
    const getPhasesForApp = (app: ApplicationWithDetails) => {
        return phases.filter(p => p.opportunity_id === app.partner_id);
    };

    const columnCount =
        2 + // Nome, Whatsapp
        (onBulkPhaseChange ? 1 : 0) +
        (showInstitutionColumn ? 1 : 0) +
        (showOpportunityColumn ? 1 : 0) +
        1 + // Status
        1 + // Elegibilidade
        (showPhaseColumn ? 1 : 0) +
        1 + // Progresso
        1 + // Data
        1; // Ações

    if (isLoading) {
        return (
            <div className="flex h-[200px] items-center justify-center">
                <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
            </div>
        );
    }

    return (
        <div className="space-y-4">
            {/* Bulk Action Bar */}
            {selectedIds.length > 0 && onBulkPhaseChange && (
                <div className="flex flex-col sm:flex-row items-center justify-between p-3 rounded-md bg-secondary/50 border gap-3 animate-in fade-in slide-in-from-top-2">
                    <span className="text-sm font-medium text-muted-foreground">
                        {selectedIds.length} candidatura(s) selecionada(s)
                    </span>
                    <div className="flex items-center gap-2 w-full sm:w-auto">
                        <Select
                            onValueChange={(val) => {
                                const finalVal = val === "none" ? null : val;
                                onBulkPhaseChange(selectedIds, finalVal);
                                setSelectedIds([]);
                            }}
                        >
                            <SelectTrigger className="w-full sm:w-[220px]">
                                <SelectValue placeholder="Mudar Fase em Massa" />
                            </SelectTrigger>
                            <SelectContent>
                                <SelectItem value="none">Sem Fase</SelectItem>
                                {/* We get phases that are relevant to the selected applications */}
                                {Array.from(new Set(filteredApplications
                                    .filter(app => selectedIds.includes(app.id))
                                    .map(app => app.partner_id)
                                )).map(oppId => {
                                    const oppPhases = phases.filter(p => p.opportunity_id === oppId);
                                    if (oppPhases.length === 0) return null;
                                    return (
                                        <div key={oppId} className="px-2 py-1">
                                            <span className="text-[10px] uppercase font-bold text-muted-foreground tracking-wider block mb-1">
                                                {filteredApplications.find(a => a.partner_id === oppId)?.partner_name || "Oportunidade"}
                                            </span>
                                            {oppPhases.map(p => (
                                                <SelectItem key={p.id} value={p.id}>
                                                    {p.name}
                                                </SelectItem>
                                            ))}
                                        </div>
                                    );
                                })}
                            </SelectContent>
                        </Select>
                    </div>
                </div>
            )}

            {/* Filters */}
            <div className="flex flex-col sm:flex-row gap-3">
                <div className="relative flex-1">
                    <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
                    <Input
                        placeholder="Buscar por nome..."
                        className="pl-9"
                        value={search}
                        onChange={(e) => setSearch(e.target.value)}
                    />
                </div>
                {institutions && (
                    <Select value={institutionFilter} onValueChange={setInstitutionFilter}>
                        <SelectTrigger className="w-full sm:w-[200px]">
                            <SelectValue placeholder="Todos os Parceiros" />
                        </SelectTrigger>
                        <SelectContent>
                            <SelectItem value="all">Todos os Parceiros</SelectItem>
                            {institutions.map((i) => (
                                <SelectItem key={i.id} value={i.id}>
                                    {i.name}
                                </SelectItem>
                            ))}
                        </SelectContent>
                    </Select>
                )}
                {partners && (
                    <Select value={opportunityFilterValue} onValueChange={handleOpportunityFilterChange}>
                        <SelectTrigger className="w-full sm:w-[220px]">
                            <SelectValue placeholder="Todas as Oportunidades" />
                        </SelectTrigger>
                        <SelectContent>
                            <SelectItem value="all">Todas as Oportunidades</SelectItem>
                            {partners.map((p) => (
                                <SelectItem key={p.id} value={p.id}>
                                    {p.name}
                                </SelectItem>
                            ))}
                        </SelectContent>
                    </Select>
                )}
                {showPhaseFilter && (
                    <Select value={phaseFilter} onValueChange={setPhaseFilter}>
                        <SelectTrigger className="w-full sm:w-[180px]">
                            <SelectValue placeholder="Todas as Fases" />
                        </SelectTrigger>
                        <SelectContent>
                            <SelectItem value="all">Todas as Fases</SelectItem>
                            {phases.map((p) => (
                                <SelectItem key={p.id} value={p.id}>
                                    {p.name}
                                </SelectItem>
                            ))}
                        </SelectContent>
                    </Select>
                )}
                <Select value={statusFilter} onValueChange={setStatusFilter}>
                    <SelectTrigger className="w-full sm:w-[180px]">
                        <SelectValue placeholder="Todos os Status" />
                    </SelectTrigger>
                    <SelectContent>
                        <SelectItem value="all">Todos os Status</SelectItem>
                        <SelectItem value="DRAFT">Rascunho</SelectItem>
                        <SelectItem value="redirected">Redirecionado</SelectItem>
                        <SelectItem value="SUBMITTED">Enviado</SelectItem>
                    </SelectContent>
                </Select>
            </div>

            {/* Table */}
            <div className="rounded-md border overflow-auto">
                <Table>
                    <TableHeader>
                        <TableRow>
                            {onBulkPhaseChange && (
                                <TableHead className="w-[40px]">
                                    <Checkbox
                                        checked={selectedIds.length > 0 && selectedIds.length === filteredApplications.length}
                                        onCheckedChange={toggleSelectAll}
                                    />
                                </TableHead>
                            )}
                            <TableHead>Nome</TableHead>
                            <TableHead>Whatsapp</TableHead>
                            {showInstitutionColumn && <TableHead>Parceiro</TableHead>}
                            {showOpportunityColumn && <TableHead>Oportunidade</TableHead>}
                            <TableHead>Status</TableHead>
                            <TableHead>Elegibilidade</TableHead>
                            {showPhaseColumn && <TableHead>Fase Atual</TableHead>}
                            <TableHead className="text-center">Progresso</TableHead>
                            <TableHead>Data</TableHead>
                            <TableHead className="text-right">Ações</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {filteredApplications.length === 0 ? (
                            <TableRow>
                                <TableCell colSpan={columnCount} className="text-center py-8 text-muted-foreground">
                                    Nenhuma candidatura encontrada.
                                </TableCell>
                            </TableRow>
                        ) : (
                            filteredApplications.map((app) => (
                                <TableRow key={app.id}>
                                    {onBulkPhaseChange && (
                                        <TableCell>
                                            <Checkbox
                                                checked={selectedIds.includes(app.id)}
                                                onCheckedChange={() => toggleSelect(app.id)}
                                            />
                                        </TableCell>
                                    )}
                                    <TableCell className="font-medium whitespace-nowrap">
                                        {app.full_name || "—"}
                                    </TableCell>
                                    <TableCell className="whitespace-nowrap">
                                        {formatPhone(app.phone)}
                                    </TableCell>
                                    {showInstitutionColumn && (
                                        <TableCell className="whitespace-nowrap">
                                            {app.institution_name || "—"}
                                        </TableCell>
                                    )}
                                    {showOpportunityColumn && (
                                        <TableCell className="whitespace-nowrap">
                                            {app.partner_name || "—"}
                                        </TableCell>
                                    )}
                                    <TableCell>
                                        <StatusBadge status={app.status} />
                                    </TableCell>
                                    <TableCell>
                                        <EligibilityCell app={app} />
                                    </TableCell>
                                    {showPhaseColumn && !onPhaseChange ? (
                                        <TableCell className="whitespace-nowrap">
                                            {phases.find(p => p.id === app.phase_id)?.name || "Sem Fase"}
                                        </TableCell>
                                    ) : showPhaseColumn ? (
                                        <TableCell className="whitespace-nowrap">
                                            <div className="flex items-center gap-1">
                                                <Select
                                                    value={app.phase_id || "none"}
                                                    onValueChange={(val) => {
                                                        if (onPhaseChange) {
                                                            onPhaseChange(app.id, val === "none" ? null : val);
                                                        }
                                                    }}
                                                >
                                                    <SelectTrigger className="h-8 w-[140px] text-xs">
                                                        <SelectValue placeholder="Sem Fase" />
                                                    </SelectTrigger>
                                                    <SelectContent>
                                                        <SelectItem value="none">Sem Fase</SelectItem>
                                                        {getPhasesForApp(app).map(p => (
                                                            <SelectItem key={p.id} value={p.id} className="text-xs">
                                                                {p.name}
                                                            </SelectItem>
                                                        ))}
                                                    </SelectContent>
                                                </Select>
                                            </div>
                                        </TableCell>
                                    ) : null}
                                    <TableCell className="text-center">
                                        {(() => {
                                            const fields = formFieldsMap[app.partner_id] || [];
                                            const ans = app.answers || {};
                                            let percent = 0;
                                            if (app.status === 'SUBMITTED' || app.status?.toUpperCase() === 'REDIRECTED') {
                                                percent = 100;
                                            } else if (fields.length > 0) {
                                                percent = calculateApplicationProgress(ans, fields);
                                            }
                                            const filled = Object.keys(ans).length;
                                            const displayTotal = percent === 100 ? filled : (fields.length || '?');
                                            return (
                                                <div className="flex flex-col items-center">
                                                    <span className="font-medium text-primary">{percent}%</span>
                                                    <span className="text-[10px] text-muted-foreground">{filled} / {displayTotal} resps</span>
                                                </div>
                                            );
                                        })()}
                                    </TableCell>
                                    <TableCell className="whitespace-nowrap text-muted-foreground">
                                        {new Date(app.created_at).toLocaleDateString("pt-BR")}
                                    </TableCell>
                                    <TableCell className="text-right">
                                        <Button
                                            variant="ghost"
                                            size="icon"
                                            onClick={() => onViewAnswers(app)}
                                            title="Ver respostas"
                                        >
                                            <Eye className="h-4 w-4" />
                                        </Button>
                                    </TableCell>
                                </TableRow>
                            ))
                        )}
                    </TableBody>
                </Table>
            </div>
        </div>
    );
}

export { STATUS_CONFIG, formatPhone };
