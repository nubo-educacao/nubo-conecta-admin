// PartnerTable.tsx — Sprint 3.8
// V1 schema table: shows name, location, logo/cover previews, brand color.

import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Edit, Image as ImageIcon, ArrowUpDown, ArrowUp, ArrowDown } from "lucide-react";
import { Partner } from "@/services/partnersService";

interface PartnerTableProps {
    partners: Partner[];
    onEdit: (partner: Partner) => void;
    sortBy?: string;
    sortOrder?: string;
    onSort?: (field: string) => void;
}

export function PartnerTable({
    partners,
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

    return (
        <div className="rounded-md border">
            <Table>
                <TableHeader>
                    <TableRow>
                        <TableHead className="w-[60px]">Logo</TableHead>
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
                        <TableHead>Localização</TableHead>
                        <TableHead>Descrição</TableHead>
                        <TableHead className="w-[60px]">Cor</TableHead>
                        <TableHead className="text-right">Ações</TableHead>
                    </TableRow>
                </TableHeader>
                <TableBody>
                    {partners.length === 0 ? (
                        <TableRow>
                            <TableCell colSpan={7} className="h-24 text-center">
                                Nenhum parceiro encontrado.
                            </TableCell>
                        </TableRow>
                    ) : (
                        partners.map((partner) => (
                            <TableRow key={partner.id}>
                                {/* Logo */}
                                <TableCell>
                                    {partner.logo_url ? (
                                        <img
                                            src={partner.logo_url}
                                            alt={partner.name}
                                            className="h-10 w-10 rounded-full object-contain border p-0.5"
                                        />
                                    ) : (
                                        <div className="flex h-10 w-10 items-center justify-center rounded-full bg-muted text-muted-foreground">
                                            <ImageIcon className="h-4 w-4" />
                                        </div>
                                    )}
                                </TableCell>
                                {/* Cover */}
                                <TableCell>
                                    {partner.cover_url ? (
                                        <img
                                            src={partner.cover_url}
                                            alt=""
                                            className="h-10 w-14 rounded-md object-cover"
                                        />
                                    ) : (
                                        <div className="flex h-10 w-14 items-center justify-center rounded-md bg-muted text-muted-foreground">
                                            <ImageIcon className="h-4 w-4" />
                                        </div>
                                    )}
                                </TableCell>
                                {/* Name */}
                                <TableCell className="font-medium">{partner.name}</TableCell>
                                {/* Location */}
                                <TableCell className="text-muted-foreground">{partner.location || "—"}</TableCell>
                                {/* Description */}
                                <TableCell className="max-w-xs truncate text-muted-foreground text-sm">
                                    {partner.description || "—"}
                                </TableCell>
                                {/* Brand Color */}
                                <TableCell>
                                    {partner.brand_color ? (
                                        <div
                                            className="h-6 w-6 rounded-full border"
                                            style={{ backgroundColor: partner.brand_color }}
                                            title={partner.brand_color}
                                        />
                                    ) : (
                                        <span className="text-xs text-muted-foreground">—</span>
                                    )}
                                </TableCell>
                                {/* Actions */}
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
