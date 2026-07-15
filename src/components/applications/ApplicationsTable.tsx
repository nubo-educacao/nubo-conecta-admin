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
import { getPartnerFormCounts } from "@/services/applicationsService";
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
    /** If provided, renders the partner filter dropdown (Admin mode) */
    partners?: PartnerOption[];
    partnerFilter?: string;
    onPartnerFilterChange?: (value: string) => void;
    onFilteredDataChange?: (applications: ApplicationWithDetails[]) => void;
    // Props for Opportunity Phases
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
    onFilteredDataChange,
    phases = [],
    onPhaseChange,
    onBulkPhaseChange,
}: ApplicationsTableProps) {
    const showPartnerColumn = !!partners;
    const [search, setSearch] = useState("");
    const [statusFilter, setStatusFilter] = useState<string>("all");
    
    // Checkbox selections for bulk actions
    const [selectedIds, setSelectedIds] = useState<string[]>([]);

    const { data: formCounts = {} } = useQuery({
        queryKey: ["partnerFormCountsTable"],
        queryFn: getPartnerFormCounts,
    });

    const filteredApplications = useMemo(() => {
        return applications.filter((app) => {
            if (statusFilter !== "all" && app.status !== statusFilter) return false;
            if (search) {
                const searchLower = search.toLowerCase();
                const nameMatch = app.full_name?.toLowerCase().includes(searchLower);
                if (!nameMatch) return false;
            }
            return true;
        });
    }, [applications, statusFilter, search]);

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
                {partners && onPartnerFilterChange && (
                    <Select value={partnerFilter || "all"} onValueChange={onPartnerFilterChange}>
                        <SelectTrigger className="w-full sm:w-[220px]">
                            <SelectValue placeholder="Todos os Parceiros" />
                        </SelectTrigger>
                        <SelectContent>
                            <SelectItem value="all">Todos os Parceiros</SelectItem>
                            {partners.map((p) => (
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
                            {showPartnerColumn && <TableHead>Parceiro</TableHead>}
                            <TableHead>Status</TableHead>
                            <TableHead>Elegibilidade</TableHead>
                            {phases.length > 0 || onPhaseChange ? <TableHead>Fase Atual</TableHead> : null}
                            <TableHead className="text-center">Progresso</TableHead>
                            <TableHead>Data</TableHead>
                            <TableHead className="text-right">Ações</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {filteredApplications.length === 0 ? (
                            <TableRow>
                                <TableCell colSpan={showPartnerColumn ? 9 : 8} className="text-center py-8 text-muted-foreground">
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
                                    {showPartnerColumn && (
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
                                    {phases.length > 0 || onPhaseChange ? (
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
                                            const filled = Object.keys(app.answers || {}).length;
                                            const totalForms = formCounts[app.partner_id] || 0;
                                            let percent = 0;
                                            if (app.status === 'SUBMITTED' || app.status?.toUpperCase() === 'REDIRECTED') {
                                                percent = 100;
                                            } else if (totalForms > 0) {
                                                percent = Math.min(100, Math.round((filled * 100) / totalForms));
                                            }
                                            const displayTotal = percent === 100 ? filled : (totalForms || '?');
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
