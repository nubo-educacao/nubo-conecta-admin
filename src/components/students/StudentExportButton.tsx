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

            // 4. Prepare "Perfil Geral" Sheet Data
            const perfilHeader = [
                "Nome Completo",
                "ID",
                "Whatsapp",
                "Idade",
                "Raça / Etnia",
                "Cidade",
                "Estado",
                "Escolaridade",
                "Renda Per Capita",
                "Cotas",
                "Candidaturas em Andamento (DRAFT)",
                "Candidaturas Concluídas",
                "Aluno Nubo",
                "Data de Cadastro"
            ];

            const perfilData = students.map(s => [
                s.full_name || "-",
                s.id,
                s.whatsapp || "-",
                s.age || "-",
                s.race || "-",
                s.city || "-",
                s.state || "-",
                s.education || "-",
                s.family_income_per_capita ? `R$ ${s.family_income_per_capita.toFixed(2)}` : "-",
                s.quota_types?.join(", ") || "-",
                s.applications_list?.filter(a => a.includes("DRAFT")).join(", ") || "-",
                s.applications_list?.filter(a => !a.includes("DRAFT")).join(", ") || "-",
                s.is_nubo_student ? "Sim" : "Não",
                new Date(s.created_at).toLocaleDateString("pt-BR")
            ]);

            // 5. Prepare "Matchs" Sheet Data
            const matchsHeader = [
                "Nome Completo",
                "ID",
                "Whatsapp",
                "Total de Matchs",
                "Lista de Matchs (Oportunidades)"
            ];

            const matchsData = students.map(s => [
                s.full_name || "-",
                s.id,
                s.whatsapp || "-",
                s.matches_count || 0,
                s.matches_list?.join(", ") || "-"
            ]);

            // 6. Prepare "Favoritos" Sheet Data
            const favoritosHeader = [
                "Nome Completo",
                "ID",
                "Whatsapp",
                "Cursos / Parceiros Favoritados"
            ];

            const favoritosData = students.map(s => [
                s.full_name || "-",
                s.id,
                s.whatsapp || "-",
                s.applications_list?.join(", ") || "-"
            ]);

            // 7. Create Workbook and Sheets
            const wb = XLSX.utils.book_new();

            const wsResumo = XLSX.utils.aoa_to_sheet(resumoData);
            const wsPerfil = XLSX.utils.aoa_to_sheet([perfilHeader, ...perfilData]);
            const wsMatchs = XLSX.utils.aoa_to_sheet([matchsHeader, ...matchsData]);
            const wsFavoritos = XLSX.utils.aoa_to_sheet([favoritosHeader, ...favoritosData]);

            wsResumo["!cols"] = [{ wch: 25 }, { wch: 35 }];
            wsPerfil["!cols"] = [{ wch: 30 }, { wch: 36 }, { wch: 15 }, { wch: 8 }, { wch: 15 }, { wch: 20 }, { wch: 8 }, { wch: 25 }, { wch: 18 }, { wch: 20 }, { wch: 30 }, { wch: 30 }, { wch: 12 }, { wch: 15 }];
            wsMatchs["!cols"] = [{ wch: 30 }, { wch: 36 }, { wch: 15 }, { wch: 15 }, { wch: 40 }];
            wsFavoritos["!cols"] = [{ wch: 30 }, { wch: 36 }, { wch: 15 }, { wch: 40 }];

            XLSX.utils.book_append_sheet(wb, wsResumo, "Resumo");
            XLSX.utils.book_append_sheet(wb, wsPerfil, "Perfil Geral");
            XLSX.utils.book_append_sheet(wb, wsMatchs, "Matchs");
            XLSX.utils.book_append_sheet(wb, wsFavoritos, "Favoritos");

            // 8. Generate File
            XLSX.writeFile(wb, "Relatorio_Estudantes_Nubo.xlsx");

            toast.success("Relatório multi-abas gerado com sucesso!", { id: "export-students" });

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
