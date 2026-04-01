
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import { SeanEllisScore } from "@/services/seanEllisService";
import { format } from "date-fns";
import { ptBR } from "date-fns/locale";
import { Check, Minus, ArrowUpDown, ArrowUp, ArrowDown } from "lucide-react";

interface SeanEllisTableProps {
    data: SeanEllisScore[];
    sortBy?: string;
    sortOrder?: string;
    onSort?: (field: string) => void;
}

export function SeanEllisTable({ data, sortBy, sortOrder, onSort }: SeanEllisTableProps) {
    const renderSortIcon = (field: string) => {
        if (sortBy !== field) return <ArrowUpDown className="ml-2 h-4 w-4 text-muted-foreground/30" />;
        return sortOrder === "asc" ? (
            <ArrowUp className="ml-2 h-4 w-4 text-primary" />
        ) : (
            <ArrowDown className="ml-2 h-4 w-4 text-primary" />
        );
    };

    if (!data || data.length === 0) {
        return (
            <div className="rounded-md border p-8 text-center text-muted-foreground">
                Nenhum resultado encontrado.
            </div>
        );
    }

    return (
        <div className="rounded-md border">
            <Table>
                <TableHeader>
                    <TableRow>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("submitted_at")}
                        >
                            <div className="flex items-center">
                                Data
                                {renderSortIcon("submitted_at")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("full_name")}
                        >
                            <div className="flex items-center">
                                Nome
                                {renderSortIcon("full_name")}
                            </div>
                        </TableHead>
                        <TableHead>Whatsapp</TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("identified")}
                        >
                            <div className="flex items-center">
                                Identificado?
                                {renderSortIcon("identified")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("disappointment_level")}
                        >
                            <div className="flex items-center">
                                Nível de Decepção
                                {renderSortIcon("disappointment_level")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("sisu_subscribed")}
                        >
                            <div className="flex items-center">
                                SISU Inscrito?
                                {renderSortIcon("sisu_subscribed")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("prouni_subscribed")}
                        >
                            <div className="flex items-center">
                                PROUNI Inscrito?
                                {renderSortIcon("prouni_subscribed")}
                            </div>
                        </TableHead>
                    </TableRow >
                </TableHeader >
                <TableBody>
                    {data.map((item) => (
                        <TableRow key={item.id}>
                            <TableCell className="whitespace-nowrap">
                                {item.submitted_at ? format(new Date(item.submitted_at), "dd/MM/yyyy HH:mm", { locale: ptBR }) : "-"}
                            </TableCell>
                            <TableCell>{item.full_name}</TableCell>
                            <TableCell>{item.whatsapp_raw}</TableCell>
                            <TableCell>
                                {item.user_id ? (
                                    <Check className="h-4 w-4 text-green-500" />
                                ) : (
                                    <Minus className="h-4 w-4 text-gray-300" />
                                )}
                            </TableCell>
                            <TableCell>{item.disappointment_level}</TableCell>
                            <TableCell>{item.sisu_subscribed}</TableCell>
                            <TableCell>{item.prouni_subscribed}</TableCell>
                        </TableRow>
                    ))}
                </TableBody>
            </Table >
        </div >
    );
}
