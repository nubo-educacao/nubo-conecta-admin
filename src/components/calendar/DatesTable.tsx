import { ImportantDate, DATE_TYPE_COLORS, DATE_TYPE_LABELS, DateType } from "@/services/calendarService";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Edit2, Trash2 } from "lucide-react";
import { format } from "date-fns";
import { ptBR } from "date-fns/locale";

interface DatesTableProps {
    dates: ImportantDate[];
    onEdit: (date: ImportantDate) => void;
    onDelete: (date: ImportantDate) => void;
}

export default function DatesTable({ dates, onEdit, onDelete }: DatesTableProps) {
    const formatDate = (dateStr: string) => {
        return format(new Date(dateStr), "dd/MM/yyyy HH:mm", { locale: ptBR });
    };

    return (
        <div className="border rounded-lg bg-card shadow-sm">
            <Table>
                <TableHeader>
                    <TableRow>
                        <TableHead>Título</TableHead>
                        <TableHead>Tipo</TableHead>
                        <TableHead>Data Início</TableHead>
                        <TableHead>Data Fim</TableHead>
                        <TableHead className="text-right">Ações</TableHead>
                    </TableRow>
                </TableHeader>
                <TableBody>
                    {dates.length === 0 ? (
                        <TableRow>
                            <TableCell
                                colSpan={5}
                                className="text-center py-10 text-muted-foreground"
                            >
                                Nenhuma data cadastrada.
                            </TableCell>
                        </TableRow>
                    ) : (
                        dates.map((date) => {
                            const typeColor =
                                DATE_TYPE_COLORS[date.type as DateType] || "#999";
                            const typeLabel =
                                DATE_TYPE_LABELS[date.type as DateType] || date.type;

                            return (
                                <TableRow key={date.id}>
                                    <TableCell className="font-medium max-w-[300px] truncate">
                                        {date.title}
                                    </TableCell>
                                    <TableCell>
                                        <Badge
                                            variant="outline"
                                            style={{
                                                borderColor: typeColor,
                                                color: typeColor,
                                            }}
                                        >
                                            {typeLabel}
                                        </Badge>
                                    </TableCell>
                                    <TableCell className="text-sm">
                                        {formatDate(date.start_date)}
                                    </TableCell>
                                    <TableCell className="text-sm text-muted-foreground">
                                        {date.end_date ? formatDate(date.end_date) : "—"}
                                    </TableCell>
                                    <TableCell className="text-right">
                                        <div className="flex items-center justify-end gap-1">
                                            <Button
                                                variant="ghost"
                                                size="icon"
                                                onClick={() => onEdit(date)}
                                            >
                                                <Edit2 className="h-4 w-4" />
                                            </Button>
                                            <Button
                                                variant="ghost"
                                                size="icon"
                                                className="text-destructive hover:text-destructive"
                                                onClick={() => onDelete(date)}
                                            >
                                                <Trash2 className="h-4 w-4" />
                                            </Button>
                                        </div>
                                    </TableCell>
                                </TableRow>
                            );
                        })
                    )}
                </TableBody>
            </Table>
        </div>
    );
}
