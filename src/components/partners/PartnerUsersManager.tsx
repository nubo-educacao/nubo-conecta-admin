import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase, createTempClient } from "@/integrations/supabase/client";
import { Partner } from "@/services/partnersService";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogDescription,
    DialogFooter,
} from "@/components/ui/dialog";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import {
    AlertDialog,
    AlertDialogAction,
    AlertDialogCancel,
    AlertDialogContent,
    AlertDialogDescription,
    AlertDialogFooter,
    AlertDialogHeader,
    AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Plus, Trash2, Loader2, UserPlus, Mail } from "lucide-react";
import { toast } from "sonner";

// ─── Types ───────────────────────────────────────────────────────────────────

interface PartnerUser {
    id: string;
    user_id: string;
    partner_id: string;
    created_at: string;
    email?: string;
}

// ─── Component ───────────────────────────────────────────────────────────────

interface PartnerUsersManagerProps {
    partners: Partner[];
}

export function PartnerUsersManager({ partners }: PartnerUsersManagerProps) {
    const queryClient = useQueryClient();
    const [selectedPartnerId, setSelectedPartnerId] = useState<string>("");
    const [isInviteDialogOpen, setIsInviteDialogOpen] = useState(false);
    const [inviteEmail, setInviteEmail] = useState("");
    const [invitePassword, setInvitePassword] = useState(""); // For new user creation
    const [activeTab, setActiveTab] = useState("link"); // "link" or "create"
    const [deleteUserId, setDeleteUserId] = useState<string | null>(null);

    // ─── Queries ─────────────────────────────────────────────────────────────

    const { data: partnerUsers = [], isLoading } = useQuery({
        queryKey: ["partner-users", selectedPartnerId],
        queryFn: async () => {
            if (!selectedPartnerId) return [];

            // Fetch partner_users records with emails via RPC
            const { data, error } = await supabase.rpc("get_partner_users", {
                p_partner_id: selectedPartnerId
            });
            
            if (error) throw error;
            return (data ?? []) as PartnerUser[];
        },
        enabled: !!selectedPartnerId,
    });

    // ─── Link Mutation ─────────────────────────────────────────────────────

    const linkMutation = useMutation({
        mutationFn: async (userId: string) => {
            const { error } = await supabase
                .from("partners_users")
                .insert({
                    user_id: userId.trim(),
                    partner_id: selectedPartnerId,
                });

            if (error) {
                if (error.code === "23505") {
                    throw new Error("Este usuário já está vinculado a este parceiro.");
                }
                if (error.code === "23503") {
                    throw new Error("User ID inválido. Verifique se o usuário existe.");
                }
                throw error;
            }
        },
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partner-users", selectedPartnerId] });
            toast.success("Usuário vinculado com sucesso!");
            setIsInviteDialogOpen(false);
            setInviteEmail("");
        },
        onError: (err: any) => {
            toast.error(err.message || "Erro ao vincular usuário.");
        },
    });

    // ─── Create & Link Mutation ──────────────────────────────────────────────

    const createAndLinkMutation = useMutation({
        mutationFn: async () => {
            // 1. Create user using temp client (so we don't logout admin)
            const tempClient = createTempClient();
            const { data: authData, error: authError } = await tempClient.auth.signUp({
                email: inviteEmail,
                password: invitePassword,
            });

            if (authError) throw authError;
            if (!authData.user) throw new Error("Erro ao criar usuário (sem dados retornados).");

            const userId = authData.user.id;

            // 2. Call RPC to elevate role and link
            const { error: rpcError } = await (supabase.rpc as any)("set_partner_role_and_link", {
                p_user_id: userId,
                p_partner_id: selectedPartnerId,
            });

            if (rpcError) throw rpcError;
        },
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partner-users", selectedPartnerId] });
            toast.success("Usuário criado, vinculado e promovido a parceiro!");
            setIsInviteDialogOpen(false);
            setInviteEmail("");
            setInvitePassword("");
        },
        onError: (err: any) => {
            toast.error(err.message || "Erro ao criar/vincular usuário.");
        }
    });



    // ─── Delete Mutation ─────────────────────────────────────────────────────

    const deleteMutation = useMutation({
        mutationFn: async (id: string) => {
            const { error } = await supabase
                .from("partners_users")
                .delete()
                .eq("id", id);
            if (error) throw error;
        },
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["partner-users", selectedPartnerId] });
            toast.success("Vínculo removido!");
            setDeleteUserId(null);
        },
        onError: () => toast.error("Erro ao remover vínculo."),
    });

    // ─── Handlers ────────────────────────────────────────────────────────────

    const handleInvite = () => {
        if (activeTab === "link") {
            if (!inviteEmail || inviteEmail.trim().length < 10) {
                toast.error("Informe um User ID válido.");
                return;
            }
            linkMutation.mutate(inviteEmail);
        } else {
            if (!inviteEmail || !inviteEmail.includes("@")) {
                toast.error("Informe um email válido.");
                return;
            }
            if (!invitePassword || invitePassword.length < 6) {
                toast.error("A senha deve ter pelo menos 6 caracteres.");
                return;
            }
            createAndLinkMutation.mutate();
        }
    };

    // ─── Render ──────────────────────────────────────────────────────────────

    return (
        <div className="space-y-4">
            {/* Partner Selector */}
            <div className="flex items-end gap-4">
                <div className="flex-1 max-w-sm space-y-2">
                    <Label>Selecione um Parceiro</Label>
                    <Select value={selectedPartnerId} onValueChange={setSelectedPartnerId}>
                        <SelectTrigger>
                            <SelectValue placeholder="Escolha um parceiro..." />
                        </SelectTrigger>
                        <SelectContent>
                            {partners.map((p) => (
                                <SelectItem key={p.id} value={p.id}>
                                    {p.name}
                                </SelectItem>
                            ))}
                        </SelectContent>
                    </Select>
                </div>
                {selectedPartnerId && (
                    <Button onClick={() => setIsInviteDialogOpen(true)} className="gap-2">
                        <UserPlus className="h-4 w-4" />
                        Convidar Usuário
                    </Button>
                )}
            </div>

            {/* Users Table */}
            {selectedPartnerId && (
                <Card>
                    <CardHeader>
                        <CardTitle className="text-lg">Usuários com Acesso</CardTitle>
                        <CardDescription>
                            {partnerUsers.length} usuário(s) vinculado(s). Eles terão acesso ao Portal do Parceiro com os dados deste parceiro.
                        </CardDescription>
                    </CardHeader>
                    <CardContent>
                        {isLoading ? (
                            <div className="flex justify-center py-8">
                                <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
                            </div>
                        ) : partnerUsers.length === 0 ? (
                            <div className="text-center py-8 text-muted-foreground">
                                <Mail className="h-8 w-8 mx-auto mb-3 opacity-50" />
                                <p>Nenhum usuário vinculado.</p>
                                <p className="text-sm">Clique em "Convidar Usuário" para enviar um convite por email.</p>
                            </div>
                        ) : (
                            <div className="rounded-md border overflow-auto">
                                <Table>
                                    <TableHeader>
                                        <TableRow>
                                            <TableHead>Email do Usuário</TableHead>
                                            <TableHead>Vinculado em</TableHead>
                                            <TableHead className="w-[80px]">Ações</TableHead>
                                        </TableRow>
                                    </TableHeader>
                                    <TableBody>
                                        {partnerUsers.map((pu) => (
                                            <TableRow key={pu.id}>
                                                <TableCell className="text-sm">{pu.email}</TableCell>
                                                <TableCell className="text-muted-foreground">
                                                    {new Date(pu.created_at).toLocaleDateString("pt-BR")}
                                                </TableCell>
                                                <TableCell>
                                                    <Button
                                                        variant="ghost"
                                                        size="icon"
                                                        onClick={() => setDeleteUserId(pu.id)}
                                                    >
                                                        <Trash2 className="h-4 w-4 text-destructive" />
                                                    </Button>
                                                </TableCell>
                                            </TableRow>
                                        ))}
                                    </TableBody>
                                </Table>
                            </div>
                        )}
                    </CardContent>
                </Card>
            )}

            {/* Invite Dialog */}
            <Dialog open={isInviteDialogOpen} onOpenChange={setIsInviteDialogOpen}>
                <DialogContent className="max-w-md">
                    <DialogHeader>
                        <DialogTitle>Gerenciar Usuários do Parceiro</DialogTitle>
                        <DialogDescription>
                            Vincule um usuário existente ou crie um novo acesso de parceiro.
                        </DialogDescription>
                    </DialogHeader>

                    <Tabs value={activeTab} onValueChange={setActiveTab} className="w-full">
                        <TabsList className="grid w-full grid-cols-2">
                            <TabsTrigger value="link">Vincular Existente</TabsTrigger>
                            <TabsTrigger value="create">Criar Novo</TabsTrigger>
                        </TabsList>

                        <TabsContent value="link" className="space-y-4 py-2">
                            <div className="space-y-2">
                                <Label>User ID (UUID)</Label>
                                <Input
                                    placeholder="ex: a1b2c3d4-e5f6-7890-abcd-ef1234567890"
                                    value={inviteEmail}
                                    onChange={(e) => setInviteEmail(e.target.value)}
                                />
                                <p className="text-xs text-muted-foreground">
                                    O usuário deve já existir no sistema (auth.users).
                                </p>
                            </div>
                        </TabsContent>

                        <TabsContent value="create" className="space-y-4 py-2">
                            <div className="space-y-2">
                                <Label>Email</Label>
                                <Input
                                    type="email"
                                    placeholder="email@parceiro.com"
                                    value={inviteEmail}
                                    onChange={(e) => setInviteEmail(e.target.value)}
                                />
                            </div>
                            <div className="space-y-2">
                                <Label>Senha</Label>
                                <Input
                                    type="password"
                                    placeholder="******"
                                    value={invitePassword}
                                    onChange={(e) => setInvitePassword(e.target.value)}
                                />
                            </div>
                        </TabsContent>
                    </Tabs>

                    <DialogFooter>
                        <Button variant="outline" onClick={() => setIsInviteDialogOpen(false)}>Cancelar</Button>
                        <Button
                            onClick={handleInvite}
                            disabled={activeTab === "link" ? linkMutation.isPending : createAndLinkMutation.isPending}
                            className="gap-2"
                        >
                            {(activeTab === "link" ? linkMutation.isPending : createAndLinkMutation.isPending) ? (
                                <Loader2 className="h-4 w-4 animate-spin" />
                            ) : (
                                <UserPlus className="h-4 w-4" />
                            )}
                            {activeTab === "link" ? "Vincular" : "Criar e Vincular"}
                        </Button>
                    </DialogFooter>
                </DialogContent>
            </Dialog>

            {/* Delete Confirmation */}
            <AlertDialog open={!!deleteUserId} onOpenChange={() => setDeleteUserId(null)}>
                <AlertDialogContent>
                    <AlertDialogHeader>
                        <AlertDialogTitle>Remover vínculo?</AlertDialogTitle>
                        <AlertDialogDescription>
                            O usuário perderá acesso ao Portal deste parceiro. Ele não será deletado do sistema.
                        </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                        <AlertDialogCancel>Cancelar</AlertDialogCancel>
                        <AlertDialogAction
                            onClick={() => deleteUserId && deleteMutation.mutate(deleteUserId)}
                            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                        >
                            Remover
                        </AlertDialogAction>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialog>
        </div>
    );
}
