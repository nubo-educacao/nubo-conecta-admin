import React, { useState, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { getAdminFunnelUsers, FunnelUserData } from "@/services/passportDashboardService";
import { 
    Table, 
    TableBody, 
    TableCell, 
    TableHead, 
    TableHeader, 
    TableRow 
} from "@/components/ui/table";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Loader2, Download, Search, Smartphone, User, History, CheckCircle2, UserCircle2, ShieldCheck } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";

export default function FunnelUsers() {
    const [searchTerm, setSearchTerm] = useState("");
    const [isExporting, setIsExporting] = useState(false);

    const { data: users = [], isLoading } = useQuery({
        queryKey: ["adminFunnelUsers"],
        queryFn: getAdminFunnelUsers,
    });

    const filteredUsers = useMemo(() => {
        if (!searchTerm) return users;
        const term = searchTerm.toLowerCase();
        return users.filter(u => 
            u.full_name?.toLowerCase().includes(term) || 
            u.whatsapp?.toLowerCase().includes(term) ||
            u.active_partner_name?.toLowerCase().includes(term) ||
            u.funnel_phase?.toLowerCase().includes(term)
        );
    }, [users, searchTerm]);

    const handleExport = async () => {
        try {
            setIsExporting(true);
            const BOM = "\uFEFF";
            const headers = ["Nome Completo", "WhatsApp", "Fase do Funil", "Fase da Candidatura", "Candidatura Ativa", "Progresso", "É Dependente?", "Nome do Responsável", "Cliques Externos"];
            const rows = users.map(u => {
                let progressStr = "—";
                if (u.progress_percent !== null && u.progress_percent !== undefined) {
                    progressStr = `${u.progress_percent}% (${u.progress_filled}/${u.progress_total} resps)`;
                }
                return [
                    u.full_name || "—",
                    u.whatsapp || "—",
                    u.funnel_phase || "—",
                    u.furthest_passport_phase || "—",
                    u.active_partner_name || "—",
                    progressStr,
                    u.is_dependent ? "Sim" : "Não",
                    u.parent_full_name || "—",
                    u.external_redirect_clicks?.toString() || "0"
                ];
            });

            const csvContent = BOM + [
                headers.join(";"),
                ...rows.map(r => r.map(c => `"${String(c).replace(/\r?\n|\r/g, ' | ').replace(/"/g, '""')}"`).join(";"))
            ].join("\n");

            const blob = new Blob([csvContent], { type: "text/csv;charset=utf-8;" });
            const url = URL.createObjectURL(blob);
            const link = document.createElement("a");
            link.href = url;
            link.download = `usuarios_funil_${new Date().toISOString().slice(0, 10)}.csv`;
            link.click();
            URL.revokeObjectURL(url);
            toast.success("Usuários exportados com sucesso!");
        } catch (e) {
            console.error(e);
            toast.error("Erro ao exportar usuários.");
        } finally {
            setIsExporting(false);
        }
    };

    if (isLoading) {
        return (
            <div className="flex h-[400px] items-center justify-center">
                <Loader2 className="h-8 w-8 animate-spin text-primary" />
            </div>
        );
    }

    return (
        <div className="container mx-auto space-y-6 p-6">
            <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
                <div>
                    <h1 className="text-3xl font-bold tracking-tight">Funil de Conversão</h1>
                    <p className="text-muted-foreground text-sm flex items-center gap-1.5 mt-1">
                        Visualize a jornada individual de cada usuário desde o início do Passaporte.
                    </p>
                </div>
                <Button variant="outline" onClick={handleExport} disabled={isExporting} className="gap-2">
                    {isExporting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
                    Exportar Lista Full
                </Button>
            </div>

            <Card>
                <CardHeader>
                    <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
                        <div>
                            <CardTitle>Listagem de Usuários</CardTitle>
                            <CardDescription>{filteredUsers.length} registros encontrados</CardDescription>
                        </div>
                        <div className="relative max-w-sm w-full">
                            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
                            <Input
                                placeholder="Buscar por nome, whatsapp ou parceiro..."
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                                className="pl-10"
                            />
                        </div>
                    </div>
                </CardHeader>
                <CardContent className="p-0">
                    <div className="overflow-x-auto">
                        <Table>
                            <TableHeader>
                                <TableRow className="bg-muted/50">
                                    <TableHead className="font-bold"><div className="flex items-center gap-2"><User className="h-4 w-4" /> Nome</div></TableHead>
                                    <TableHead className="font-bold"><div className="flex items-center gap-2"><Smartphone className="h-4 w-4" /> WhatsApp</div></TableHead>
                                    <TableHead className="font-bold"><div className="flex items-center gap-2"><History className="h-4 w-4" /> Fase no Funil</div></TableHead>
                                    <TableHead className="font-bold">Fase da Candidatura</TableHead>
                                    <TableHead className="font-bold"><div className="flex items-center gap-2"><Smartphone className="h-4 w-4" /> Candidatura Ativa</div></TableHead>
                                    <TableHead className="font-bold text-center"><div className="flex items-center justify-center gap-2"><CheckCircle2 className="h-4 w-4" /> Progresso</div></TableHead>
                                    <TableHead className="font-bold">Tipo</TableHead>
                                    <TableHead className="font-bold">Titular/Responsável</TableHead>
                                    <TableHead className="font-bold text-center">Cliques Externos</TableHead>
                                </TableRow>
                            </TableHeader>
                            <TableBody>
                                {filteredUsers.length === 0 ? (
                                    <TableRow>
                                        <TableCell colSpan={9} className="h-24 text-center text-muted-foreground">
                                            Nenhum usuário encontrado.
                                        </TableCell>
                                    </TableRow>
                                ) : (
                                    filteredUsers.map((user, idx) => (
                                        <TableRow key={`${user.whatsapp}-${idx}`} className="hover:bg-muted/30 transition-colors">
                                            <TableCell className="font-medium">{user.full_name || "—"}</TableCell>
                                            <TableCell className="text-sm font-mono">{user.whatsapp || "—"}</TableCell>
                                            <TableCell>
                                                <Badge variant="secondary" className="font-normal border-blue-200 bg-blue-50 text-blue-700">
                                                    {user.funnel_phase || "—"}
                                                </Badge>
                                            </TableCell>
                                            <TableCell className="text-xs text-muted-foreground italic">
                                                {user.furthest_passport_phase || "—"}
                                            </TableCell>
                                            <TableCell className="font-medium text-blue-800">
                                                {user.active_partner_name || "—"}
                                            </TableCell>
                                            <TableCell className="text-center font-medium">
                                                {user.progress_percent !== null && user.progress_percent !== undefined ? (
                                                    <div className="flex flex-col items-center">
                                                        <span className={user.progress_percent === 100 ? "text-green-600" : "text-primary"}>
                                                            {user.progress_percent}%
                                                        </span>
                                                        <span className="text-[10px] text-muted-foreground whitespace-nowrap">
                                                            {user.progress_filled}/{user.progress_total} resps
                                                        </span>
                                                    </div>
                                                ) : "—"}
                                            </TableCell>
                                            <TableCell>
                                                {user.is_dependent ? (
                                                    <Badge variant="outline" className="gap-1 border-orange-200 text-orange-700 bg-orange-50/50">
                                                        <UserCircle2 className="h-3 w-3" /> Dependente
                                                    </Badge>
                                                ) : (
                                                    <Badge variant="outline" className="gap-1 border-green-200 text-green-700 bg-green-50/50">
                                                        <ShieldCheck className="h-3 w-3" /> Titular
                                                    </Badge>
                                                )}
                                            </TableCell>
                                            <TableCell className="text-sm">
                                                {user.is_dependent ? user.parent_full_name : "—"}
                                            </TableCell>
                                            <TableCell className="text-center font-medium">
                                                {user.external_redirect_clicks > 0 ? (
                                                    <Badge variant="outline" className="text-sky-600 border-sky-200 bg-sky-50">
                                                        {user.external_redirect_clicks}
                                                    </Badge>
                                                ) : "—"}
                                            </TableCell>
                                        </TableRow>
                                    ))
                                )}
                            </TableBody>
                        </Table>
                    </div>
                </CardContent>
            </Card>
        </div>
    );
}
