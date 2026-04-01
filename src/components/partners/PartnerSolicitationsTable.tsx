import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Search } from "lucide-react";
import { PartnerSolicitation } from "@/services/partnerSolicitationsService";

interface PartnerSolicitationsTableProps {
    solicitations: PartnerSolicitation[];
    onView: (solicitation: PartnerSolicitation) => void;
}

export function PartnerSolicitationsTable({
    solicitations,
    onView,
}: PartnerSolicitationsTableProps) {
    const formatPhoneNumber = (phone: string | undefined) => {
        if (!phone) return "N/A";
        return phone.replace(/(\d{2})(\d{5})(\d{4})/, "($1) $2-$3");
    };

    return (
        <div className="rounded-md border">
            <Table>
                <TableHeader>
                    <TableRow>
                        <TableHead>Instituição</TableHead>
                        <TableHead>Responsável</TableHead>
                        <TableHead>Whatsapp</TableHead>
                        <TableHead>E-mail</TableHead>
                        <TableHead className="text-right">Ações</TableHead>
                    </TableRow>
                </TableHeader>
                <TableBody>
                    {solicitations.length === 0 ? (
                        <TableRow>
                            <TableCell colSpan={5} className="h-24 text-center">
                                Nenhuma solicitação encontrada.
                            </TableCell>
                        </TableRow>
                    ) : (
                        solicitations.map((solicitation) => (
                            <TableRow key={solicitation.id}>
                                <TableCell className="font-medium">
                                    {solicitation.institution_name}
                                </TableCell>
                                <TableCell>{solicitation.contact_name}</TableCell>
                                <TableCell>{formatPhoneNumber(solicitation.whatsapp)}</TableCell>
                                <TableCell>{solicitation.email || "N/A"}</TableCell>
                                <TableCell className="text-right">
                                    <Button
                                        variant="ghost"
                                        size="icon"
                                        onClick={() => onView(solicitation)}
                                    >
                                        <Search className="h-4 w-4" />
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
