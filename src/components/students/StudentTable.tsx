
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Eye, ArrowUpDown, ArrowUp, ArrowDown } from "lucide-react";
import { StudentProfile } from "@/services/studentsService";

interface StudentTableProps {
    students: StudentProfile[];
    onViewDetails: (student: StudentProfile) => void;
    sortBy?: string;
    sortOrder?: string;
    onSort?: (field: string) => void;
}

export function StudentTable({ students, onViewDetails, sortBy, sortOrder, onSort }: StudentTableProps) {
    const renderSortIcon = (field: string) => {
        if (sortBy !== field) return <ArrowUpDown className="ml-2 h-4 w-4 text-muted-foreground/30" />;
        return sortOrder === "asc" ? (
            <ArrowUp className="ml-2 h-4 w-4 text-primary" />
        ) : (
            <ArrowDown className="ml-2 h-4 w-4 text-primary" />
        );
    };

    return (
        <div className="rounded-md border">
            <Table>
                <TableHeader>
                    <TableRow>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("full_name")}
                        >
                            <div className="flex items-center">
                                Nome
                                {renderSortIcon("full_name")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("age")}
                        >
                            <div className="flex items-center">
                                Idade
                                {renderSortIcon("age")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("city")}
                        >
                            <div className="flex items-center">
                                Cidade
                                {renderSortIcon("city")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("education")}
                        >
                            <div className="flex items-center">
                                Escolaridade
                                {renderSortIcon("education")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("whatsapp")}
                        >
                            <div className="flex items-center">
                                Whatsapp
                                {renderSortIcon("whatsapp")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("is_nubo_student")}
                        >
                            <div className="flex items-center">
                                Aluno Nubo
                                {renderSortIcon("is_nubo_student")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("created_at")}
                        >
                            <div className="flex items-center">
                                Data de Cadastro
                                {renderSortIcon("created_at")}
                            </div>
                        </TableHead>
                        <TableHead className="text-right">Ações</TableHead>
                    </TableRow>
                </TableHeader>
                <TableBody>
                    {students.length === 0 ? (
                        <TableRow>
                            <TableCell colSpan={8} className="h-24 text-center">
                                Nenhum estudante encontrado.
                            </TableCell>
                        </TableRow>
                    ) : (
                        students.map((student) => (
                            <TableRow key={student.id}>
                                <TableCell className="font-medium">{student.full_name || "N/A"}</TableCell>
                                <TableCell>{student.age || "N/A"}</TableCell>
                                <TableCell>{student.city || "N/A"}</TableCell>
                                <TableCell>{student.education || "N/A"}</TableCell>
                                <TableCell>{student.whatsapp || "N/A"}</TableCell>
                                <TableCell>{student.is_nubo_student ? "Sim" : "Não"}</TableCell>
                                <TableCell>{student.created_at ? new Date(student.created_at).toLocaleDateString("pt-BR") : "N/A"}</TableCell>
                                <TableCell className="text-right">
                                    <Button
                                        variant="ghost"
                                        size="sm"
                                        onClick={() => onViewDetails(student)}
                                        className="gap-2"
                                    >
                                        <Eye className="h-4 w-4" />
                                        Ver detalhes
                                    </Button>
                                </TableCell>
                            </TableRow>
                        ))
                    )}
                </TableBody>
            </Table>
        </div>
    );
}

// Helper function for exporting data (as implied by the instruction and code snippet)
export const getStudentExportData = (students: StudentProfile[]) => {
    const headers = [
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

    const data = students.map(s => [
        s.id,
        s.full_name,
        s.age,
        s.city,
        s.state,
        s.education,
        s.whatsapp || "-",
        s.is_nubo_student ? "Sim" : "Não",
        s.created_at ? new Date(s.created_at).toLocaleDateString("pt-BR") : "N/A"
    ]);

    const columnWidths = [
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

    return { headers, data, columnWidths };
};
