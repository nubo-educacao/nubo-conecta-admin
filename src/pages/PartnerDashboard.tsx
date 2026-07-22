import { useState, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import {
    getMyPartnerId,
    getPartnerFormFields,
    getPartnerDetails,
    getPartnerRedirectUsers,
    getPartnerOpportunities,
} from "@/services/partnerPortalService";
import {
    getApplicationsByInstitution,
    getEligibleCountByInstitution,
    getPartnerFormCounts,
    getOpportunityPhases,
    updateApplicationPhase,
    updateApplicationsPhaseBulk,
    type ApplicationWithDetails,
} from "@/services/applicationsService";
import { getPartnerFunnel } from "@/services/passportDashboardService";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import {
    Download,
    Users,
    CheckCircle2,
    XCircle,
    FileSpreadsheet,
    MousePointerClick,
    Upload,
} from "lucide-react";
import { toast } from "sonner";
import ApplicationsTable from "@/components/applications/ApplicationsTable";
import RedirectUsersTable from "@/components/applications/RedirectUsersTable";
import ApplicationAnswersModal from "@/components/applications/ApplicationAnswersModal";
import BulkCsvImportModal from "@/components/applications/BulkCsvImportModal";
import { buildApplicationsExport, downloadApplicationsCsv } from "@/lib/applicationsExport";
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip as RechartsTooltip, ResponsiveContainer } from "recharts";

// ─── Excel Export ────────────────────────────────────────────────────────────
// Shared helper (ADR-0015) — see src/lib/applicationsExport.ts. showPartnerColumn
// is false here: the partner portal is already scoped to a single institution.

function exportToExcel(
    applications: ApplicationWithDetails[],
    formFields: import("@/services/partnerPortalService").PartnerFormField[],
    partnerName: string,
    formCounts?: Record<string, number>,
    phases?: import("@/services/applicationsService").OpportunityPhase[]
) {
    const { headers, rows } = buildApplicationsExport(applications, formFields, {
        showPartnerColumn: false,
        formCounts,
        phases,
    });
    downloadApplicationsCsv(
        headers,
        rows,
        `inscricoes_${partnerName.replace(/\s+/g, "_").toLowerCase()}_${new Date().toISOString().slice(0, 10)}.csv`
    );
    toast.success("Arquivo exportado com sucesso!");
}

// ─── Main Component ──────────────────────────────────────────────────────────

export default function PartnerDashboard() {
    const [selectedApp, setSelectedApp] = useState<ApplicationWithDetails | null>(null);
    const [modalOpen, setModalOpen] = useState(false);
    const [csvModalOpen, setCsvModalOpen] = useState(false);
    const [filteredApps, setFilteredApps] = useState<ApplicationWithDetails[]>([]);

    // 1. Resolve the partner_id for this user
    const { data: partnerId, isLoading: loadingPartnerId } = useQuery({
        queryKey: ["myPartnerId"],
        queryFn: getMyPartnerId,
    });

    // 2. Fetch partner details
    const { data: partner } = useQuery({
        queryKey: ["partnerDetails", partnerId],
        queryFn: () => getPartnerDetails(partnerId!),
        enabled: !!partnerId,
    });

    // 3. Fetch form field definitions
    const { data: formFields = [] } = useQuery({
        queryKey: ["partnerFormFields", partnerId],
        queryFn: () => getPartnerFormFields(partnerId!),
        enabled: !!partnerId,
    });

    // 4. Fetch applications for this partner institution
    const { data: applications = [], isLoading: loadingApps, refetch: refetchApps } = useQuery({
        queryKey: ["applicationsWithDetails", partnerId],
        queryFn: () => getApplicationsByInstitution(partnerId!),
        enabled: !!partnerId,
    });

    // 4.2 Fetch opportunities to get the opportunityId
    const { data: opportunities = [] } = useQuery({
        queryKey: ["partnerOpportunities", partnerId],
        queryFn: () => getPartnerOpportunities(partnerId!),
        enabled: !!partnerId,
    });

    const opportunityId = opportunities.length > 0 ? opportunities[0].id : null;

    // 4.5 Fetch opportunity phases
    const { data: phases = [] } = useQuery({
        queryKey: ["opportunityPhases", opportunityId],
        queryFn: () => getOpportunityPhases(opportunityId!),
        enabled: !!opportunityId,
    });

    // 5. Fetch eligible count for this partner institution
    const { data: eligibleCount = 0 } = useQuery({
        queryKey: ["eligibleCount", partnerId],
        queryFn: () => getEligibleCountByInstitution(partnerId!),
        enabled: !!partnerId,
    });

    // 6. Fetch form counts for calculating completion on the fly
    const { data: formCounts = {} } = useQuery({
        queryKey: ["partnerFormCountsTable"],
        queryFn: getPartnerFormCounts,
    });

    const completionChartData = useMemo(() => {
        const buckets = {
            "1. Até 25%": 0,
            "2. Até 50%": 0,
            "3. Até 75%": 0,
            "4. Até 100%": 0
        };

        filteredApps.forEach(app => {
            const filled = Object.keys(app.answers || {}).length;
            const totalForms = formCounts[app.partner_id] || 0;
            let percent = 0;
            if (app.status === 'SUBMITTED' || app.status?.toUpperCase() === 'REDIRECTED') {
                percent = 100;
            } else if (totalForms > 0) {
                percent = Math.min(100, Math.round((filled * 100) / totalForms));
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
    }, [filteredApps, formCounts]);

    // 7. Fetch partner funnel
    const { data: funnelData } = useQuery({
        queryKey: ["partnerFunnel"],
        queryFn: getPartnerFunnel,
    });

    // 8. Fetch external redirect users
    const { data: redirectUsers = [] } = useQuery({
        queryKey: ["partnerRedirectUsers", partnerId],
        queryFn: () => getPartnerRedirectUsers(partnerId!),
        enabled: !!partnerId,
    });

    // ─── Stats ───────────────────────────────────────────────────────────────

    const stats = useMemo(() => {
        const total = filteredApps.length;

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

        const submitted = filteredApps.filter((a) => a.status === "SUBMITTED" || a.status?.toLowerCase() === "redirected").length;
        const myFunnel = funnelData?.find(f => f.partner_id === partnerId);
        const clicks = myFunnel?.total_unique_clicks || 0;
        return { total, eligible, submitted, clicks };
    }, [filteredApps, funnelData, partnerId]);

    // ─── Handlers ────────────────────────────────────────────────────────────

    const handleViewAnswers = (app: ApplicationWithDetails) => {
        setSelectedApp(app);
        setModalOpen(true);
    };

    const handlePhaseChange = async (appId: string, phaseId: string | null) => {
        try {
            await updateApplicationPhase(appId, phaseId);
            toast.success("Fase atualizada com sucesso!");
            refetchApps();
        } catch (err) {
            toast.error("Erro ao atualizar fase do candidato.");
        }
    };

    const handleBulkPhaseChange = async (appIds: string[], phaseId: string | null) => {
        try {
            await updateApplicationsPhaseBulk(appIds, phaseId);
            toast.success("Fases atualizadas em massa com sucesso!");
            refetchApps();
        } catch (err) {
            toast.error("Erro ao atualizar fases em massa.");
        }
    };

    // ─── Loading & Error States ──────────────────────────────────────────────

    if (loadingPartnerId || loadingApps) {
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
            <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
                <div>
                    <h1 className="text-2xl font-bold tracking-tight">{partner?.name || "Portal do Parceiro"}</h1>
                    <p className="text-muted-foreground">
                        Gerencie as candidaturas dos estudantes
                    </p>
                </div>
                <div className="flex items-center gap-2">
                    <Button
                        onClick={() => setCsvModalOpen(true)}
                        variant="outline"
                        className="flex items-center gap-2"
                    >
                        <Upload className="h-4 w-4" />
                        Importar CSV
                    </Button>
                    <Button
                        onClick={() => exportToExcel(filteredApps, formFields, partner?.name || "parceiro", formCounts, phases)}
                        disabled={filteredApps.length === 0}
                        className="flex items-center gap-2"
                    >
                        <Download className="h-4 w-4" />
                        Exportar Excel
                    </Button>
                </div>
            </div>

            {/* Stats Cards */}
            <div className="grid grid-cols-1 sm:grid-cols-4 gap-4">
                <Card>
                    <CardContent className="pt-6 flex items-center gap-4">
                        <div className="p-3 rounded-full bg-orange-500/10">
                            <MousePointerClick className="h-5 w-5 text-orange-500" />
                        </div>
                        <div>
                            <p className="text-2xl font-bold">{stats.clicks}</p>
                            <p className="text-xs text-muted-foreground">Cliques no Perfil</p>
                        </div>
                    </CardContent>
                </Card>
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
                        Distribuição do percentual de preenchimento do seu formulário.
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
                        isLoading={loadingApps}
                        onViewAnswers={handleViewAnswers}
                        onFilteredDataChange={setFilteredApps}
                        partners={opportunities}
                        phases={phases}
                        onPhaseChange={handlePhaseChange}
                        onBulkPhaseChange={handleBulkPhaseChange}
                    />
                </CardContent>
            </Card>

            {/* Redirect Users Table */}
            {redirectUsers.length > 0 && (
                <RedirectUsersTable redirectUsers={redirectUsers} />
            )}

            {/* Answers Modal */}
            <ApplicationAnswersModal
                application={selectedApp}
                formFields={formFields}
                open={modalOpen}
                onOpenChange={setModalOpen}
            />

            <BulkCsvImportModal
                open={csvModalOpen}
                onOpenChange={setCsvModalOpen}
                applications={applications}
                phases={phases}
                onBulkPhaseChange={handleBulkPhaseChange}
            />
        </div>
    );
}
