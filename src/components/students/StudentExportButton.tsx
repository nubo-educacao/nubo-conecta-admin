import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Download, Loader2 } from "lucide-react";
import { StudentFilters, getStudents, getStudentStats } from "@/services/studentsService";
import * as XLSX from "xlsx";
import { toast } from "sonner";

interface StudentExportButtonProps {
    filters: StudentFilters;
}

export function StudentExportButton({ filters }: StudentExportButtonProps) {
    const [isExporting, setIsExporting] = useState(false);

    const handleExport = async () => {
        try {
            setIsExporting(true);
            toast.loading("Gerando relatório...", { id: "export-students" });

            // 1. Fetch Stats
            const stats = await getStudentStats(filters);

            // 2. Fetch All Students (using a large page size limit)
            // Assuming max 10000 for now, or we could loop pages if needed.
            const { data: students } = await getStudents(0, 10000, filters);

            if (!students || students.length === 0) {
                toast.error("Nenhum estudante encontrado para exportar.", { id: "export-students" });
                return;
            }

            // 3. Prepare "Resumo" (Resume) Sheet Data
            const resumoData = [
                ["Resumo da Seleção"],
                [""],
                ["Total de Estudantes", stats.total_students],
                ["Total de Cidades", stats.total_cities],
                ["Total de Estados", stats.total_states],
                ["Idade Média", stats.average_age],
                [""],
                ["Filtros Utilizados"],
                ["Nome", filters.fullName || "-"],
                ["Cidade", filters.city || "-"],
                ["Estado", filters.state || "-"],
                ["Escolaridade", filters.education || "-"],
                ["Idade Mínima", filters.ageMin || "-"],
                ["Idade Máxima", filters.ageMax || "-"],
                ["Renda Mínima", filters.incomeMin || "-"],
                ["Renda Máxima", filters.incomeMax || "-"],
                ["Cotas", filters.quotaTypes?.join(", ") || "-"],
                ["Aluno Nubo", filters.isNuboStudent === true ? "Sim" : filters.isNuboStudent === false ? "Não" : "-"]
            ];

            // 4. Prepare "Estudantes" (Students) Sheet Data
            const estudantesHeader = [
                "ID",
                "Nome Completo",
                "Idade",
                "Cidade",
                "Estado",
                "Escolaridade",
                "Whatsapp",
                "Aluno Nubo",
                "Data de Cadastro"
            ];

            const estudantesData = students.map(s => [
                s.id,
                s.full_name,
                s.age,
                s.city,
                s.state,
                s.education,
                s.whatsapp || "-",
                s.is_nubo_student ? "Sim" : "Não",
                new Date(s.created_at).toLocaleDateString("pt-BR")
            ]);

            // 5. Create Workbook and Sheets
            const wb = XLSX.utils.book_new();

            const wsResumo = XLSX.utils.aoa_to_sheet(resumoData);
            const wsEstudantes = XLSX.utils.aoa_to_sheet([estudantesHeader, ...estudantesData]);

            // Adjust column widths for better readability
            wsResumo["!cols"] = [{ wch: 25 }, { wch: 35 }];
            wsEstudantes["!cols"] = [
                { wch: 36 }, // ID
                { wch: 30 }, // Name
                { wch: 10 }, // Age
                { wch: 20 }, // City
                { wch: 10 }, // State
                { wch: 25 }, // Education
                { wch: 15 }, // Whatsapp
                { wch: 12 }, // Is Nubo
                { wch: 15 }  // Date
            ];

            XLSX.utils.book_append_sheet(wb, wsResumo, "Resumo");
            XLSX.utils.book_append_sheet(wb, wsEstudantes, "Estudantes");

            // 6. Generate File
            XLSX.writeFile(wb, "Relatorio_Estudantes.xlsx");

            toast.success("Relatório gerado com sucesso!", { id: "export-students" });

        } catch (error) {
            console.error("Export failed:", error);
            toast.error("Erro ao gerar relatório.", { id: "export-students" });
        } finally {
            setIsExporting(false);
        }
    };

    return (
        <Button
            variant="outline"
            onClick={handleExport}
            disabled={isExporting}
            className="gap-2"
        >
            {isExporting ? (
                <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
                <Download className="h-4 w-4" />
            )}
            Exportar seleção
        </Button>
    );
}
