import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import { Plus, Edit2, Loader2 } from "lucide-react";
import UserModal from "@/components/users/UserModal";
import { Badge } from "@/components/ui/badge";
import { toast } from "sonner";

interface BackofficeUser {
    id: string;
    email: string;
    permissions: string[];
}

export default function Users() {
    const [users, setUsers] = useState<BackofficeUser[]>([]);
    const [loading, setLoading] = useState(true);
    const [modalOpen, setModalOpen] = useState(false);
    const [selectedUser, setSelectedUser] = useState<BackofficeUser | undefined>();

    const fetchUsers = async () => {
        setLoading(true);
        try {
            const { data, error } = await supabase.rpc("get_backoffice_users" as any);
            if (error) throw error;
            setUsers((data as any) || []);
        } catch (error: any) {
            toast.error("Erro ao carregar usuários: " + error.message);
        } finally {
            setLoading(false);
        }
    };

    useEffect(() => {
        fetchUsers();
    }, []);

    const handleEdit = (user: BackofficeUser) => {
        setSelectedUser(user);
        setModalOpen(true);
    };

    const handleCreate = () => {
        setSelectedUser(undefined);
        setModalOpen(true);
    };

    return (
        <div className="space-y-6">
            <div className="flex items-center justify-between">
                <div>
                    <h1 className="text-3xl font-bold tracking-tight">Controle de Usuários</h1>
                    <p className="text-muted-foreground">
                        Gerencie quem tem acesso ao painel administrativo e suas permissões.
                    </p>
                </div>
                <Button onClick={handleCreate} className="gap-2">
                    <Plus className="h-4 w-4" /> Novo Usuário
                </Button>
            </div>

            <div className="border rounded-lg bg-card shadow-sm">
                <Table>
                    <TableHeader>
                        <TableRow>
                            <TableHead>E-mail</TableHead>
                            <TableHead>Permissões</TableHead>
                            <TableHead className="text-right">Ações</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {loading ? (
                            <TableRow>
                                <TableCell colSpan={3} className="text-center py-10">
                                    <Loader2 className="h-8 w-8 animate-spin mx-auto text-muted-foreground" />
                                </TableCell>
                            </TableRow>
                        ) : users.length === 0 ? (
                            <TableRow>
                                <TableCell colSpan={3} className="text-center py-10 text-muted-foreground">
                                    Nenhum usuário de backoffice encontrado.
                                </TableCell>
                            </TableRow>
                        ) : (
                            users.map((user) => (
                                <TableRow key={user.id}>
                                    <TableCell className="font-medium">{user.email}</TableCell>
                                    <TableCell>
                                        <div className="flex flex-wrap gap-1">
                                            {user.permissions.map((p) => (
                                                <Badge key={p} variant="secondary">
                                                    {p}
                                                </Badge>
                                            ))}
                                        </div>
                                    </TableCell>
                                    <TableCell className="text-right">
                                        <Button
                                            variant="ghost"
                                            size="icon"
                                            onClick={() => handleEdit(user)}
                                        >
                                            <Edit2 className="h-4 w-4" />
                                        </Button>
                                    </TableCell>
                                </TableRow>
                            ))
                        )}
                    </TableBody>
                </Table>
            </div>

            <UserModal
                open={modalOpen}
                onOpenChange={setModalOpen}
                user={selectedUser}
                onSuccess={fetchUsers}
            />
        </div>
    );
}
