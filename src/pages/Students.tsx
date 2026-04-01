
import { useState, useRef } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Download } from "lucide-react";
import { Button } from "@/components/ui/button";
import { StudentTable } from "@/components/students/StudentTable";
import { StudentDetailsModal } from "@/components/students/StudentDetailsModal";
import { StudentFilterModal } from "@/components/students/StudentFilterModal";
import { StudentStats } from "@/components/students/StudentStats";
import { getStudents, getStudentStats, StudentProfile, importNuboStudents, StudentFilters } from "@/services/studentsService";
import Papa from "papaparse";
import { toast } from "sonner";
import { Filter } from "lucide-react";
import { useStudentFilters } from "@/hooks/useStudentFilters";
import { StudentExportButton } from "@/components/students/StudentExportButton";

export default function Students() {
    const [selectedStudentId, setSelectedStudentId] = useState<string | null>(null);
    const [isDialogOpen, setIsDialogOpen] = useState(false);

    // Filter State
    const [isFilterOpen, setIsFilterOpen] = useState(false);
    const { filters, setFilters, clearFilters } = useStudentFilters("students-filters");

    const fileInputRef = useRef<HTMLInputElement>(null);
    const queryClient = useQueryClient();

    const [page, setPage] = useState(0);
    const [sortBy, setSortBy] = useState("created_at");
    const [sortOrder, setSortOrder] = useState("desc");
    const pageSize = 20;

    const { data, isLoading } = useQuery({
        queryKey: ["students", page, filters, sortBy, sortOrder],
        queryFn: () => getStudents(page, pageSize, filters, sortBy, sortOrder),
    });

    const { data: stats, isLoading: isLoadingStats } = useQuery({
        queryKey: ["studentStats", filters],
        queryFn: () => getStudentStats(filters),
    });

    const students = data?.data || [];
    const totalCount = data?.count || 0;
    const totalPages = Math.ceil(totalCount / pageSize);

    const handleSort = (field: string) => {
        if (sortBy === field) {
            setSortOrder(sortOrder === "asc" ? "desc" : "asc");
        } else {
            setSortBy(field);
            setSortOrder("asc");
        }
        setPage(0);
    };

    const handleImportClick = () => {
        fileInputRef.current?.click();
    };

    const handleApplyFilters = (newFilters: StudentFilters) => {
        setFilters(newFilters);
        setPage(0); // Reset to first page on filter change
    };

    const handleClearFilters = () => {
        clearFilters();
        setPage(0);
    };

    const handleFileUpload = async (event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        Papa.parse(file, {
            header: true,
            skipEmptyLines: true,
            complete: async (results) => {
                try {
                    toast.loading("Importing students...", { id: "import-toast" }); // Using id to update later
                    const { imported_whitelist_entries, updated_existing_profiles } = await importNuboStudents(results.data);
                    toast.success(`Import successful! Added ${imported_whitelist_entries} to whitelist and updated ${updated_existing_profiles} existing profiles.`, { id: "import-toast" });
                    queryClient.invalidateQueries({ queryKey: ["students"] });
                    queryClient.invalidateQueries({ queryKey: ["studentStats"] });
                } catch (error) {
                    console.error("Import error:", error);
                    toast.error("Failed to import students. Please try again.", { id: "import-toast" });
                } finally {
                    // Reset input
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

    const handleViewDetails = (student: StudentProfile) => {
        setSelectedStudentId(student.id);
        setIsDialogOpen(true);
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
                    <h1 className="text-3xl font-bold tracking-tight">Estudantes</h1>
                    <p className="text-muted-foreground">
                        Gerencie e visualize os estudantes cadastrados na plataforma.
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
                        Importar alunos Nubo
                    </Button>
                </div>
            </div>

            <StudentStats stats={stats} isLoading={isLoadingStats} />

            <div className="space-y-4">
                <div className="flex items-center justify-between">
                    <h2 className="text-xl font-semibold">Listagem de Estudantes</h2>
                    <div className="flex gap-2">
                        <StudentExportButton filters={filters} />
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
                </div>
                <StudentTable
                    students={students}
                    onViewDetails={handleViewDetails}
                    sortBy={sortBy}
                    sortOrder={sortOrder}
                    onSort={handleSort}
                />
            </div>

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

            <StudentDetailsModal
                isOpen={isDialogOpen}
                onOpenChange={setIsDialogOpen}
                studentId={selectedStudentId}
            />

            <StudentFilterModal
                open={isFilterOpen}
                onOpenChange={setIsFilterOpen}
                filters={filters}
                onApplyFilters={handleApplyFilters}
                onClearFilters={handleClearFilters}
            />
        </div>
    );
}
