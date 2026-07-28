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

            // 2. Fetch All Students
            const { data: students } = await getStudents(0, 10000, filters);

            if (!students || students.length === 0) {
                toast.error("Nenhum estudante encontrado para exportar.", { id: "export-students" });
                return;
            }

            // 3. Prepare "Resumo" Sheet Data
            const resumoData = [
                ["Resumo da Seleção", ""],
                [""],
                ["Total de Estudantes", stats.total_students],
                ["Total de Cidades", stats.total_cities],
                ["Total de Estados", stats.total_states],
                ["Idade Média", stats.average_age],
                [""],
                ["Filtros Utilizados", ""],
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

            const perfilData = students.map(s => {
                const draftCount = Number(s.draft_applications_count) || 0;
                const completedCount = Number(s.completed_applications_count) || 0;

                const draftStr = draftCount > 0 ? (s.draft_applications_list ? `${s.draft_applications_list} (${draftCount})` : draftCount.toString()) : "-";
                const completedStr = completedCount > 0 ? (s.completed_applications_list ? `${s.completed_applications_list} (${completedCount})` : completedCount.toString()) : "-";
                const incomeStr = s.per_capita_income != null && !isNaN(Number(s.per_capita_income))
                    ? `R$ ${Number(s.per_capita_income).toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
                    : "-";
                const cotasStr = Array.isArray(s.quota_types) && s.quota_types.length > 0 ? s.quota_types.join(", ") : "-";

                return [
                    s.full_name || "-",
                    s.id,
                    s.whatsapp || "-",
                    s.age ?? "-",
                    s.race || "-",
                    s.city || "-",
                    s.state || "-",
                    s.education || "-",
                    incomeStr,
                    cotasStr,
                    draftStr,
                    completedStr,
                    s.is_nubo_student ? "Sim" : "Não",
                    s.created_at ? new Date(s.created_at).toLocaleDateString("pt-BR") : "-"
                ];
            });

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
                s.total_matches ?? 0,
                s.matches_list || "-"
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
                s.favorites_list || "-"
            ]);

            // 7. Create Workbook and Sheets
            const wb = XLSX.utils.book_new();

            const wsResumo = XLSX.utils.aoa_to_sheet(resumoData);
            const wsPerfil = XLSX.utils.aoa_to_sheet([perfilHeader, ...perfilData]);
            const wsMatchs = XLSX.utils.aoa_to_sheet([matchsHeader, ...matchsData]);
            const wsFavoritos = XLSX.utils.aoa_to_sheet([favoritosHeader, ...favoritosData]);

            // Adjust Column Widths
            wsResumo["!cols"] = [{ wch: 30 }, { wch: 35 }];
            wsPerfil["!cols"] = [
                { wch: 30 }, // Nome Completo
                { wch: 36 }, // ID
                { wch: 16 }, // Whatsapp
                { wch: 8 },  // Idade
                { wch: 15 }, // Raça / Etnia
                { wch: 20 }, // Cidade
                { wch: 8 },  // Estado
                { wch: 25 }, // Escolaridade
                { wch: 18 }, // Renda
                { wch: 25 }, // Cotas
                { wch: 35 }, // DRAFT
                { wch: 35 }, // Concluídas
                { wch: 12 }, // Aluno Nubo
                { wch: 15 }  // Data
            ];
            wsMatchs["!cols"] = [
                { wch: 30 }, // Nome Completo
                { wch: 36 }, // ID
                { wch: 16 }, // Whatsapp
                { wch: 15 }, // Total
                { wch: 80 }  // Lista
            ];
            wsFavoritos["!cols"] = [
                { wch: 30 }, // Nome Completo
                { wch: 36 }, // ID
                { wch: 16 }, // Whatsapp
                { wch: 60 }  // Favoritos
            ];

            XLSX.utils.book_append_sheet(wb, wsResumo, "Resumo");
            XLSX.utils.book_append_sheet(wb, wsPerfil, "Perfil Geral");
            XLSX.utils.book_append_sheet(wb, wsMatchs, "Matchs");
            XLSX.utils.book_append_sheet(wb, wsFavoritos, "Favoritos");

            // 8. Generate File
            XLSX.writeFile(wb, "Relatorio_Estudantes_Nubo.xlsx");

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
