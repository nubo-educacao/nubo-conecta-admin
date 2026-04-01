import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
} from "@/components/ui/dialog";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import { Loader2 } from "lucide-react";
import { toast } from "sonner";

interface AffiliatesModalProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    influencerCode: string | null;
    influencerName: string | null;
}

interface AffiliateUser {
    id: string;
    full_name: string | null;
    phone: string | null;
    age: number | null;
    city: string | null;
    created_at: string;
    last_sign_in_at: string | null;
}

export default function AffiliatesModal({
    open,
    onOpenChange,
    influencerCode,
    influencerName,
}: AffiliatesModalProps) {
    const [loading, setLoading] = useState(false);
    const [affiliates, setAffiliates] = useState<AffiliateUser[]>([]);

    useEffect(() => {
        if (open && influencerCode) {
            fetchAffiliates();
        }
    }, [open, influencerCode]);

    const fetchAffiliates = async () => {
        setLoading(true);
        try {
            const { data, error } = await supabase.rpc("get_influencer_affiliates" as any, {
                influencer_code: influencerCode,
            });

            if (error) throw error;
            setAffiliates((data as any) || []);
        } catch (error: any) {
            toast.error("Erro ao carregar afiliados: " + error.message);
        } finally {
            setLoading(false);
        }
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="max-w-4xl max-h-[80vh] flex flex-col">
                <DialogHeader>
                    <DialogTitle>Afiliados de {influencerName}</DialogTitle>
                </DialogHeader>
                <div className="flex-1 overflow-auto py-4">
                    <Table>
                        <TableHeader>
                            <TableRow>
                                <TableHead>Nome</TableHead>
                                <TableHead>Telefone</TableHead>
                                <TableHead>Idade</TableHead>
                                <TableHead>Cidade</TableHead>
                                <TableHead>Cadastro</TableHead>
                                <TableHead>Último Acesso</TableHead>
                            </TableRow>
                        </TableHeader>
                        <TableBody>
                            {loading ? (
                                <TableRow>
                                    <TableCell colSpan={6} className="text-center py-10">
                                        <Loader2 className="h-8 w-8 animate-spin mx-auto text-muted-foreground" />
                                    </TableCell>
                                </TableRow>
                            ) : affiliates.length === 0 ? (
                                <TableRow>
                                    <TableCell colSpan={6} className="text-center py-10 text-muted-foreground">
                                        Nenhum afiliado encontrado para este influencer.
                                    </TableCell>
                                </TableRow>
                            ) : (
                                affiliates.map((user) => (
                                    <TableRow key={user.id}>
                                        <TableCell className="font-medium whitespace-nowrap">{user.full_name || "Sem nome"}</TableCell>
                                        <TableCell className="whitespace-nowrap">{user.phone || "-"}</TableCell>
                                        <TableCell>{user.age || "-"}</TableCell>
                                        <TableCell>{user.city || "-"}</TableCell>
                                        <TableCell className="whitespace-nowrap">
                                            {new Date(user.created_at).toLocaleDateString("pt-BR")}
                                        </TableCell>
                                        <TableCell className="whitespace-nowrap">
                                            {user.last_sign_in_at
                                                ? new Date(user.last_sign_in_at).toLocaleDateString("pt-BR")
                                                : "-"}
                                        </TableCell>
                                    </TableRow>
                                ))
                            )}
                        </TableBody>
                    </Table>
                </div>
            </DialogContent>
        </Dialog>
    );
}

