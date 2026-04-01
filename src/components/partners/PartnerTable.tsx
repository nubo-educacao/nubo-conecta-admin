import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Edit, Image as ImageIcon, ArrowUpDown, ArrowUp, ArrowDown } from "lucide-react";
import { Partner } from "@/services/partnersService";
import { Badge } from "@/components/ui/badge";

interface PartnerTableProps {
    partners: Partner[];
    clicksMap: Record<string, number>;
    onEdit: (partner: Partner) => void;
    sortBy?: string;
    sortOrder?: string;
    onSort?: (field: string) => void;
}

export function PartnerTable({
    partners,
    clicksMap,
    onEdit,
    sortBy,
    sortOrder,
    onSort
}: PartnerTableProps) {
    const renderSortIcon = (field: string) => {
        if (sortBy !== field) return <ArrowUpDown className="ml-2 h-4 w-4 text-muted-foreground/30" />;
        return sortOrder === "asc" ? (
            <ArrowUp className="ml-2 h-4 w-4 text-primary" />
        ) : (
            <ArrowDown className="ml-2 h-4 w-4 text-primary" />
        );
    };

    const formatDateRange = (dates: any) => {
        const datesObj = Array.isArray(dates) ? dates[0] : dates;

        if (!datesObj || !(datesObj as any).start_date) return "N/A";

        const formatDate = (dateStr: string) => {
            const date = new Date(dateStr);
            if (isNaN(date.getTime())) return "";
            return date.toLocaleDateString("pt-BR", {
                day: "numeric",
                month: "short",
                year: "numeric",
                timeZone: "UTC"
            });
        };

        const start = formatDate((datesObj as any).start_date);
        const end = (datesObj as any).end_date ? formatDate((datesObj as any).end_date) : "Indeterminado";

        return `${start} - ${end}`;
    };

    return (
        <div className="rounded-md border">
            <Table>
                <TableHeader>
                    <TableRow>
                        <TableHead className="w-[80px]">Capa</TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("name")}
                        >
                            <div className="flex items-center">
                                Nome
                                {renderSortIcon("name")}
                            </div>
                        </TableHead>
                        <TableHead
                            className="cursor-pointer hover:bg-muted/50 transition-colors"
                            onClick={() => onSort?.("type")}
                        >
                            <div className="flex items-center">
                                Tipo
                                {renderSortIcon("type")}
                            </div>
                        </TableHead>
                        <TableHead>Período</TableHead>
                        <TableHead>Status</TableHead>
                        <TableHead className="text-right">Total de Cliques</TableHead>
                        <TableHead className="text-right">Ações</TableHead>
                    </TableRow>
                </TableHeader>
                <TableBody>
                    {partners.length === 0 ? (
                        <TableRow>
                            <TableCell colSpan={6} className="h-24 text-center">
                                Nenhum parceiro encontrado.
                            </TableCell>
                        </TableRow>
                    ) : (
                        partners.map((partner) => (
                            <TableRow key={partner.id}>
                                <TableCell>
                                    {partner.coverimage ? (
                                        <img
                                            src={partner.coverimage}
                                            alt={partner.name}
                                            className="h-10 w-10 rounded-md object-cover"
                                        />
                                    ) : (
                                        <div className="flex h-10 w-10 items-center justify-center rounded-md bg-muted text-muted-foreground">
                                            <ImageIcon className="h-5 w-5" />
                                        </div>
                                    )}
                                </TableCell>
                                <TableCell className="font-medium">{partner.name}</TableCell>
                                <TableCell>{partner.type || "N/A"}</TableCell>
                                <TableCell>{formatDateRange(partner.dates)}</TableCell>
                                <TableCell>
                                    <Badge variant={partner.applications_open ? "default" : "secondary"}>
                                        {partner.applications_open ? "Abertas" : "Encerradas"}
                                    </Badge>
                                </TableCell>
                                <TableCell className="text-right">
                                    {clicksMap[partner.id] || 0}
                                </TableCell>
                                <TableCell className="text-right">
                                    <Button
                                        variant="ghost"
                                        size="icon"
                                        onClick={() => onEdit(partner)}
                                    >
                                        <Edit className="h-4 w-4" />
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
