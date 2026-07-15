import React, { useState, useMemo } from "react";
import Papa from "papaparse";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Upload, XCircle, CheckCircle2, AlertCircle } from "lucide-react";
import { Checkbox } from "@/components/ui/checkbox";
import { Badge } from "@/components/ui/badge";
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
import type { ApplicationWithDetails, OpportunityPhase } from "@/services/applicationsService";
import { STATUS_CONFIG } from "./ApplicationsTable";

interface BulkCsvImportModalProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    applications: ApplicationWithDetails[];
    phases: OpportunityPhase[];
    onBulkPhaseChange: (appIds: string[], phaseId: string | null) => void;
}

export default function BulkCsvImportModal({
    open,
    onOpenChange,
    applications,
    phases,
    onBulkPhaseChange,
}: BulkCsvImportModalProps) {
    const [step, setStep] = useState<"upload" | "review">("upload");
    const [matchedApps, setMatchedApps] = useState<ApplicationWithDetails[]>([]);
    const [selectedIds, setSelectedIds] = useState<string[]>([]);
    const [error, setError] = useState<string | null>(null);
    const [totalCsvPhones, setTotalCsvPhones] = useState(0);

    // Reset state when modal opens
    React.useEffect(() => {
        if (open) {
            setStep("upload");
            setMatchedApps([]);
            setSelectedIds([]);
            setError(null);
            setTotalCsvPhones(0);
        }
    }, [open]);

    const normalizePhone = (phone: string | null) => {
        if (!phone) return "";
        return phone.replace(/\D/g, "");
    };

    const handleFileUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (!file) return;

        setError(null);
        Papa.parse(file, {
            header: true,
            skipEmptyLines: true,
            complete: (results) => {
                const data = results.data as any[];
                if (data.length === 0) {
                    setError("O arquivo CSV está vazio.");
                    return;
                }

                // Identify the WhatsApp column (case insensitive)
                const headers = Object.keys(data[0]);
                const whatsappCol = headers.find((h) => h.toLowerCase().includes("whatsapp"));

                if (!whatsappCol) {
                    setError("Não foi encontrada nenhuma coluna com o nome 'Whatsapp' no arquivo CSV.");
                    return;
                }

                // Extract and normalize phone numbers from the CSV
                const csvPhones = data
                    .map((row) => normalizePhone(row[whatsappCol]))
                    .filter(Boolean);

                if (csvPhones.length === 0) {
                    setError("Nenhum número de Whatsapp válido foi encontrado na coluna.");
                    return;
                }

                // Match with applications
                const matched = applications.filter((app) => {
                    const appPhone = normalizePhone(app.phone);
                    return appPhone && csvPhones.includes(appPhone);
                });

                if (matched.length === 0) {
                    setError("Nenhum candidato correspondente foi encontrado com esses números.");
                    return;
                }

                setTotalCsvPhones(csvPhones.length);
                setMatchedApps(matched);
                setSelectedIds(matched.map((m) => m.id)); // Select all by default
                setStep("review");
            },
            error: (err) => {
                setError(`Erro ao ler o arquivo: ${err.message}`);
            },
        });
    };

    const toggleSelect = (id: string) => {
        setSelectedIds((prev) =>
            prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]
        );
    };

    const toggleSelectAll = () => {
        if (selectedIds.length === matchedApps.length) {
            setSelectedIds([]);
        } else {
            setSelectedIds(matchedApps.map((app) => app.id));
        }
    };

    const getEligibilityStr = (app: ApplicationWithDetails): string => {
        if (!app.eligibility_results || !Array.isArray(app.eligibility_results) || app.eligibility_results.length === 0) return "—";
        const isGrouped = app.eligibility_results.length > 0 && 'partner_id' in app.eligibility_results[0];
        if (isGrouped) {
            const resultForPartner = app.eligibility_results.find((r: any) => r.partner_id === app.partner_id);
            if (!resultForPartner || resultForPartner.total_criteria === undefined || resultForPartner.total_criteria === null) return "—";
            return `${resultForPartner.met_criteria || 0}/${resultForPartner.total_criteria}`;
        } else {
            const total = app.eligibility_results.length;
            const met = app.eligibility_results.filter((r: any) => r.met === true).length;
            return `${met}/${total}`;
        }
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="sm:max-w-[900px] max-h-[90vh] flex flex-col">
                <DialogHeader>
                    <DialogTitle>Importar Alterações em Massa (CSV)</DialogTitle>
                </DialogHeader>

                {step === "upload" && (
                    <div className="flex flex-col items-center justify-center py-12 px-4 text-center border-2 border-dashed rounded-lg border-muted-foreground/25">
                        <Upload className="h-10 w-10 text-muted-foreground mb-4" />
                        <h3 className="font-semibold text-lg mb-1">Selecione o arquivo CSV</h3>
                        <p className="text-sm text-muted-foreground mb-6 max-w-md">
                            O arquivo deve conter uma coluna chamada <strong>Whatsapp</strong> (igual ao exportado) com os números dos candidatos que deseja alterar a fase.
                        </p>
                        
                        <Button asChild>
                            <label className="cursor-pointer">
                                Escolher Arquivo
                                <input
                                    type="file"
                                    accept=".csv"
                                    className="hidden"
                                    onChange={handleFileUpload}
                                />
                            </label>
                        </Button>

                        {error && (
                            <div className="mt-6 flex items-start gap-2 text-destructive bg-destructive/10 p-3 rounded-md text-sm text-left max-w-md w-full">
                                <AlertCircle className="h-5 w-5 shrink-0 mt-0.5" />
                                <p>{error}</p>
                            </div>
                        )}
                    </div>
                )}

                {step === "review" && (
                    <div className="flex flex-col flex-1 overflow-hidden min-h-0">
                        <div className="mb-4 text-sm text-muted-foreground flex flex-col gap-1">
                            <span>
                                Encontrados <strong>{matchedApps.length}</strong> candidatos correspondentes.
                            </span>
                            {totalCsvPhones > matchedApps.length && (
                                <span className="text-destructive font-medium flex items-center gap-1">
                                    <AlertCircle className="h-4 w-4" />
                                    Nenhum candidato foi encontrado para {totalCsvPhones - matchedApps.length} dos {totalCsvPhones} números.
                                </span>
                            )}
                        </div>

                        {selectedIds.length > 0 && (
                            <div className="flex flex-col sm:flex-row items-center justify-between p-3 mb-4 rounded-md bg-secondary/50 border gap-3 shrink-0">
                                <span className="text-sm font-medium text-muted-foreground">
                                    {selectedIds.length} candidatura(s) selecionada(s)
                                </span>
                                <div className="flex items-center gap-2 w-full sm:w-auto">
                                    <Select
                                        onValueChange={(val) => {
                                            const finalVal = val === "none" ? null : val;
                                            onBulkPhaseChange(selectedIds, finalVal);
                                            onOpenChange(false);
                                        }}
                                    >
                                        <SelectTrigger className="w-full sm:w-[220px] bg-background">
                                            <SelectValue placeholder="Mudar Fase em Massa" />
                                        </SelectTrigger>
                                        <SelectContent>
                                            <SelectItem value="none">Sem Fase</SelectItem>
                                            {Array.from(new Set(matchedApps
                                                .filter(app => selectedIds.includes(app.id))
                                                .map(app => app.partner_id)
                                            )).map(oppId => {
                                                const oppPhases = phases.filter(p => p.opportunity_id === oppId);
                                                if (oppPhases.length === 0) return null;
                                                return (
                                                    <div key={oppId} className="px-2 py-1">
                                                        <span className="text-[10px] uppercase font-bold text-muted-foreground tracking-wider block mb-1">
                                                            {matchedApps.find(a => a.partner_id === oppId)?.partner_name || "Oportunidade"}
                                                        </span>
                                                        {oppPhases.map(phase => (
                                                            <SelectItem key={phase.id} value={phase.id}>
                                                                {phase.name}
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

                        <div className="rounded-md border flex-1 overflow-auto">
                            <Table>
                                <TableHeader className="sticky top-0 bg-background shadow-sm z-10">
                                    <TableRow>
                                        <TableHead className="w-12 text-center">
                                            <Checkbox
                                                checked={
                                                    matchedApps.length > 0 &&
                                                    selectedIds.length === matchedApps.length
                                                }
                                                onCheckedChange={toggleSelectAll}
                                                aria-label="Select all"
                                            />
                                        </TableHead>
                                        <TableHead>Nome</TableHead>
                                        <TableHead>Whatsapp</TableHead>
                                        <TableHead>Status</TableHead>
                                        <TableHead>Elegibilidade</TableHead>
                                        <TableHead>Fase Atual</TableHead>
                                    </TableRow>
                                </TableHeader>
                                <TableBody>
                                    {matchedApps.map((app) => {
                                        const isSelected = selectedIds.includes(app.id);
                                        const statusConfig = STATUS_CONFIG[app.status] || { label: app.status, variant: "outline", icon: XCircle };
                                        const StatusIcon = statusConfig.icon;
                                        
                                        const currentPhase = app.phase_id ? phases.find(p => p.id === app.phase_id)?.name : null;
                                        const phaseName = currentPhase || "Sem Fase";

                                        return (
                                            <TableRow key={app.id} data-state={isSelected && "selected"}>
                                                <TableCell className="text-center">
                                                    <Checkbox
                                                        checked={isSelected}
                                                        onCheckedChange={() => toggleSelect(app.id)}
                                                        aria-label={`Select ${app.full_name}`}
                                                    />
                                                </TableCell>
                                                <TableCell className="font-medium">{app.full_name || "—"}</TableCell>
                                                <TableCell>{app.phone || "—"}</TableCell>
                                                <TableCell>
                                                    <Badge variant={statusConfig.variant} className="flex items-center gap-1 w-fit whitespace-nowrap">
                                                        <StatusIcon className="h-3 w-3" />
                                                        {statusConfig.label}
                                                    </Badge>
                                                </TableCell>
                                                <TableCell>{getEligibilityStr(app)}</TableCell>
                                                <TableCell>
                                                    <Badge variant="outline" className="bg-primary/5 border-primary/20 text-primary">
                                                        {phaseName}
                                                    </Badge>
                                                </TableCell>
                                            </TableRow>
                                        );
                                    })}
                                </TableBody>
                            </Table>
                        </div>
                    </div>
                )}
            </DialogContent>
        </Dialog>
    );
}
