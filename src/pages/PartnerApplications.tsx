import { useState, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import {
    getApplicationsWithDetails,
    getPartnersList,
    getInstitutionsList,
    getAllPhases,
    getEligibleCountForPartner,
    getPartnerFormFieldsMap,
    type ApplicationWithDetails,
} from "@/services/applicationsService";
import { calculateApplicationProgress } from "@/utils/calculateApplicationProgress";
import { getPartnerFormFields, type PartnerFormField } from "@/services/partnerPortalService";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import {
    Download,
    Users,
    CheckCircle2,
    FileSpreadsheet,
} from "lucide-react";
import { toast } from "sonner";
import ApplicationsTable from "@/components/applications/ApplicationsTable";
import ApplicationAnswersModal from "@/components/applications/ApplicationAnswersModal";
import { buildApplicationsExport, downloadApplicationsCsv } from "@/lib/applicationsExport";
import type { OpportunityPhase } from "@/services/applicationsService";
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip as RechartsTooltip, ResponsiveContainer } from "recharts";

// ─── Excel Export ────────────────────────────────────────────────────────────
// Shared helper (ADR-0015) — see src/lib/applicationsExport.ts. showPartnerColumn
// is the only legitimate difference vs. the partner-portal export (PartnerDashboard.tsx).

function exportToExcel(
    applications: ApplicationWithDetails[],
    formFields: PartnerFormField[],
    partnerName: string,
    formFieldsMap?: Record<string, PartnerFormField[]>,
    phases?: OpportunityPhase[]
) {
    const { headers, rows } = buildApplicationsExport(applications, formFields, {
        showPartnerColumn: true,
        formFieldsMap,
        phases,
    });
    downloadApplicationsCsv(
        headers,
        rows,
        `candidaturas_${partnerName.replace(/\s+/g, "_").toLowerCase()}_${new Date().toISOString().slice(0, 10)}.csv`
    );
    toast.success("Arquivo exportado com sucesso!");
}

// ─── Main Component ──────────────────────────────────────────────────────────

export default function PartnerApplications() {
    const [selectedApp, setSelectedApp] = useState<ApplicationWithDetails | null>(null);
    const [modalOpen, setModalOpen] = useState(false);
    const [partnerFilter, setPartnerFilter] = useState<string>("all");
    const [filteredApps, setFilteredApps] = useState<ApplicationWithDetails[]>([]);

    // 1. Fetch opportunities list for the Oportunidade filter
    const { data: partners = [] } = useQuery({
        queryKey: ["partnersList"],
        queryFn: getPartnersList,
    });

    // 1.1 Fetch partner institutions for the Parceiro filter (ADR-0014)
    const { data: institutions = [] } = useQuery({
        queryKey: ["institutionsList"],
        queryFn: getInstitutionsList,
    });

    // 1.2 Fetch all opportunity phases for the Fase filter (ADR-0014)
    const { data: allPhases = [] } = useQuery({
        queryKey: ["allPhases"],
        queryFn: getAllPhases,
    });

    // 2. Fetch all applications (or filtered by partner)
    const effectivePartnerId = partnerFilter === "all" ? undefined : partnerFilter;

    const { data: applications = [], isLoading } = useQuery({
        queryKey: ["applicationsWithDetails", effectivePartnerId ?? "all"],
        queryFn: () => getApplicationsWithDetails(effectivePartnerId),
    });

    // 3. Fetch form fields for the filtered partner
    const { data: formFields = [] } = useQuery({
        queryKey: ["partnerFormFields", effectivePartnerId],
        queryFn: () => getPartnerFormFields(effectivePartnerId!),
        enabled: !!effectivePartnerId,
    });



    // 5. Fetch form fields map for smart completion calculation
    const { data: formFieldsMap = {} } = useQuery({
        queryKey: ["partnerFormFieldsMap"],
        queryFn: getPartnerFormFieldsMap,
    });

    const completionChartData = useMemo(() => {
        const buckets = {
            "1. Até 25%": 0,
            "2. Até 50%": 0,
            "3. Até 75%": 0,
            "4. Até 100%": 0
        };

        filteredApps.forEach(app => {
            const fields = formFieldsMap[app.partner_id] || [];
            let percent = 0;
            if (app.status === 'SUBMITTED' || app.status?.toUpperCase() === 'REDIRECTED') {
                percent = 100;
            } else if (fields.length > 0) {
                percent = calculateApplicationProgress(app.answers || {}, fields);
            }

            if (percent <= 25) buckets["1. Até 25%"]++;
            else if (percent <= 50) buckets["2. Até 50%"]++;
            else if (percent <= 75) buckets["3. Até 75%"]++;
            else buckets["4. Até 100%"]++;
        });

        return Object.keys(buckets).sort().map(bucket => ({
            name: bucket,
            count: buckets[bucket as keyof typeof buckets]
        }));
    }, [filteredApps, formFieldsMap]);

    // ─── Stats ───────────────────────────────────────────────────────────────

    const stats = useMemo(() => {
        const total = filteredApps.length;
        const submitted = filteredApps.filter((a) => a.status === "SUBMITTED" || a.status?.toLowerCase() === "redirected").length;

        const eligible = filteredApps.filter((app) => {
            if (!app.eligibility_results || !Array.isArray(app.eligibility_results) || app.eligibility_results.length === 0) return false;
            const isGrouped = app.eligibility_results.length > 0 && 'partner_id' in app.eligibility_results[0];
            if (isGrouped) {
                const resultForPartner = app.eligibility_results.find((r: any) => r.partner_id === app.partner_id);
                if (!resultForPartner) return false;
                const totalCriteria = resultForPartner.total_criteria || 0;
                const metCriteria = resultForPartner.met_criteria || 0;
                return metCriteria === totalCriteria && totalCriteria > 0;
            } else {
                const totalCriteria = app.eligibility_results.length;
                const metCriteria = app.eligibility_results.filter((r: any) => r.met === true).length;
                return metCriteria === totalCriteria && totalCriteria > 0;
            }
        }).length;

        return { total, eligible, submitted };
    }, [filteredApps]);

    // ─── Handlers ────────────────────────────────────────────────────────────

    const handleViewAnswers = (app: ApplicationWithDetails) => {
        setSelectedApp(app);
        setModalOpen(true);
    };

    return (
        <div className="container mx-auto space-y-6 p-6">
            {/* Page Header */}
            <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
                <div>
                    <h1 className="text-3xl font-bold tracking-tight">Candidaturas</h1>
                    <p className="text-muted-foreground">
                        Visualize todas as candidaturas dos estudantes
                    </p>
                </div>
                <Button
                    onClick={() => exportToExcel(filteredApps, formFields, partners.find(p => p.id === partnerFilter)?.name || "Geral", formFieldsMap, allPhases)}
                    disabled={filteredApps.length === 0}
                    className="flex items-center gap-2"
                >
                    <Download className="h-4 w-4" />
                    Exportar Excel
                </Button>
            </div>

            {/* Stats Cards */}
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
                <Card>
                    <CardContent className="pt-6 flex items-center gap-4">
                        <div className="p-3 rounded-full bg-primary/10">
                            <Users className="h-5 w-5 text-primary" />
                        </div>
                        <div>
                            <p className="text-2xl font-bold">{stats.total}</p>
                            <p className="text-xs text-muted-foreground">Total de Inscrições</p>
                        </div>
                    </CardContent>
                </Card>
                <Card>
                    <CardContent className="pt-6 flex items-center gap-4">
                        <div className="p-3 rounded-full bg-green-500/10">
                            <CheckCircle2 className="h-5 w-5 text-green-500" />
                        </div>
                        <div>
                            <p className="text-2xl font-bold">{stats.eligible}</p>
                            <p className="text-xs text-muted-foreground">Elegíveis</p>
                        </div>
                    </CardContent>
                </Card>
                <Card>
                    <CardContent className="pt-6 flex items-center gap-4">
                        <div className="p-3 rounded-full bg-blue-500/10">
                            <FileSpreadsheet className="h-5 w-5 text-blue-500" />
                        </div>
                        <div>
                            <p className="text-2xl font-bold">{stats.submitted}</p>
                            <p className="text-xs text-muted-foreground">Enviados</p>
                        </div>
                    </CardContent>
                </Card>
            </div>

            {/* Progression Chart */}
            <Card>
                <CardHeader>
                    <CardTitle className="text-lg">Progresso das Candidaturas</CardTitle>
                    <CardDescription>
                        Distribuição do percentual de preenchimento dos formulários {effectivePartnerId ? 'deste parceiro' : 'geral'}.
                    </CardDescription>
                </CardHeader>
                <CardContent className="h-[250px] w-full">
                    <ResponsiveContainer width="100%" height="100%">
                        <BarChart data={completionChartData} margin={{ top: 10, right: 10, left: -20, bottom: 0 }}>
                            <CartesianGrid strokeDasharray="3 3" vertical={false} />
                            <XAxis dataKey="name" fontSize={12} />
                            <YAxis fontSize={12} allowDecimals={false} />
                            <RechartsTooltip cursor={{ fill: 'transparent' }} />
                            <Bar dataKey="count" fill="#10b981" radius={[4, 4, 0, 0]} name="Candidaturas" />
                        </BarChart>
                    </ResponsiveContainer>
                </CardContent>
            </Card>

            {/* Applications Table */}
            <Card>
                <CardHeader>
                    <CardTitle className="text-lg">Candidaturas</CardTitle>
                    <CardDescription>
                        {applications.length} registros
                    </CardDescription>
                </CardHeader>
                <CardContent>
                    <ApplicationsTable
                        applications={applications}
                        isLoading={isLoading}
                        onViewAnswers={handleViewAnswers}
                        partners={partners}
                        partnerFilter={partnerFilter}
                        onPartnerFilterChange={setPartnerFilter}
                        institutions={institutions}
                        phases={allPhases}
                        onFilteredDataChange={setFilteredApps}
                    />
                </CardContent>
            </Card>

            {/* Answers Modal */}
            <ApplicationAnswersModal
                application={selectedApp}
                formFields={formFields}
                open={modalOpen}
                onOpenChange={setModalOpen}
            />
        </div>
    );
}
