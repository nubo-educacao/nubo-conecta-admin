
import { useState, useRef } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Download, Filter } from "lucide-react";
import { Button } from "@/components/ui/button";
import { toast } from "sonner";
import { StudentFilters } from "@/services/studentsService";
import { StudentFilterModal } from "@/components/students/StudentFilterModal";
import Papa from "papaparse";
import { SeanEllisStatsDisplay } from "@/components/seanellis/SeanEllisStats";
import { SeanEllisTable } from "@/components/seanellis/SeanEllisTable";
import { getSeanEllisData, getSeanEllisStats, importSeanEllisData } from "@/services/seanEllisService";
import { useStudentFilters } from "@/hooks/useStudentFilters";

export default function SeanEllis() {
    const fileInputRef = useRef<HTMLInputElement>(null);
    const queryClient = useQueryClient();

    // Filter State - Reusing StudentFilters as requested
    const [isFilterOpen, setIsFilterOpen] = useState(false);
    const { filters, setFilters, clearFilters } = useStudentFilters("sean-ellis-filters");

    const [page, setPage] = useState(0);
    const [sortBy, setSortBy] = useState("submitted_at");
    const [sortOrder, setSortOrder] = useState("desc");
    const pageSize = 20;

    const { data, isLoading } = useQuery({
        queryKey: ["seanEllisData", page, filters, sortBy, sortOrder],
        queryFn: () => getSeanEllisData(page, pageSize, filters, sortBy, sortOrder),
    });

    const { data: stats, isLoading: isLoadingStats } = useQuery({
        queryKey: ["seanEllisStats", filters],
        queryFn: () => getSeanEllisStats(filters),
    });

    const scores = data?.data || [];
    const totalCount = data?.count || 0;
    const totalPages = Math.ceil(totalCount / pageSize);

    const handleImportClick = () => {
        fileInputRef.current?.click();
    };

    const handleFileUpload = async (event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        Papa.parse(file, {
            header: true,
            skipEmptyLines: true,
            complete: async (results) => {
                try {
                    toast.loading("Importing Sean Ellis data...", { id: "import-sean-ellis" });
                    const { count } = await importSeanEllisData(results.data);
                    toast.success(`Import successful! Added ${count} entries.`, { id: "import-sean-ellis" });
                    queryClient.invalidateQueries({ queryKey: ["seanEllisData"] });
                    queryClient.invalidateQueries({ queryKey: ["seanEllisStats"] });
                } catch (error) {
                    console.error("Import error:", error);
                    toast.error("Failed to import data. Please try again.", { id: "import-sean-ellis" });
                } finally {
                    if (fileInputRef.current) {
                        fileInputRef.current.value = "";
                    }
                }
            },
            error: (error) => {
                console.error("CSV Parse error:", error);
                toast.error("Failed to parse CSV file.");
            }
        });
    };

    const handleApplyFilters = (newFilters: StudentFilters) => {
        setFilters(newFilters);
        setPage(0);
    };

    const handleClearFilters = () => {
        clearFilters();
        setPage(0);
    };

    const handleSort = (field: string) => {
        if (sortBy === field) {
            setSortOrder(sortOrder === "asc" ? "desc" : "asc");
        } else {
            setSortBy(field);
            setSortOrder("asc");
        }
        setPage(0);
    };

    if (isLoading) {
        return (
            <div className="flex h-[400px] items-center justify-center">
                <Loader2 className="h-8 w-8 animate-spin text-primary" />
            </div>
        );
    }

    return (
        <div className="container mx-auto space-y-8 p-6">
            <div className="flex items-center justify-between">
                <div>
                    <h1 className="text-3xl font-bold tracking-tight">Sean Ellis Score</h1>
                    <p className="text-muted-foreground">
                        Análise de Product-Market Fit e feedback dos usuários.
                    </p>
                </div>
                <div className="flex gap-2">
                    <input
                        type="file"
                        ref={fileInputRef}
                        onChange={handleFileUpload}
                        className="hidden"
                        accept=".csv"
                    />
                    <Button onClick={handleImportClick} className="gap-2">
                        <Download className="h-4 w-4" />
                        Importar respostas
                    </Button>
                </div>
            </div>

            <SeanEllisStatsDisplay stats={stats} isLoading={isLoadingStats} />

            <div className="space-y-4">
                <div className="flex items-center justify-between">
                    <h2 className="text-xl font-semibold">Respostas</h2>
                    <Button
                        variant="outline"
                        size="sm"
                        className="gap-2"
                        onClick={() => setIsFilterOpen(true)}
                    >
                        <Filter className="h-4 w-4" />
                        Filtrar
                    </Button>
                </div>

                <SeanEllisTable
                    data={scores}
                    sortBy={sortBy}
                    sortOrder={sortOrder}
                    onSort={handleSort}
                />
            </div >

            <div className="flex items-center justify-end space-x-2 py-4">
                <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setPage((p) => Math.max(0, p - 1))}
                    disabled={page === 0}
                >
                    Anterior
                </Button>
                <div className="text-sm text-muted-foreground">
                    Página {page + 1} de {totalPages || 1}
                </div>
                <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setPage((p) => Math.min(totalPages - 1, p + 1))}
                    disabled={page >= totalPages - 1}
                >
                    Próxima
                </Button>
            </div>

            {/* Reusing StudentFilterModal as it contains the required filters */}
            <StudentFilterModal
                open={isFilterOpen}
                onOpenChange={setIsFilterOpen}
                filters={filters}
                onApplyFilters={handleApplyFilters}
                onClearFilters={handleClearFilters}
            />
        </div >
    );
}
