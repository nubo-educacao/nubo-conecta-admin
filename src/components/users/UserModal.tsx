import { useState, useEffect } from "react";
import { supabase, createTempClient } from "@/integrations/supabase/client";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Checkbox } from "@/components/ui/checkbox";
import { toast } from "sonner";

interface UserModalProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    user?: {
        id: string;
        email: string;
        permissions: string[];
    };
    onSuccess: () => void;
}

const AVAILABLE_PERMISSIONS = [
    "Dashboard",
    "Conversas",
    "Insights AI",
    "Erros",
    "Influencers",
    "Parceiros",
    "Estudantes",
    "Controle de usuários",
    "Sean Ellis Score",
    "Calendário",
    "Conhecimento"
];

export default function UserModal({ open, onOpenChange, user, onSuccess }: UserModalProps) {
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [selectedPermissions, setSelectedPermissions] = useState<string[]>([]);
    const [loading, setLoading] = useState(false);

    useEffect(() => {
        if (user) {
            setEmail(user.email);
            setSelectedPermissions(user.permissions);
        } else {
            setEmail("");
            setPassword("");
            setSelectedPermissions([]);
        }
    }, [user, open]);

    const handleTogglePermission = (permission: string) => {
        setSelectedPermissions((prev) =>
            prev.includes(permission)
                ? prev.filter((p) => p !== permission)
                : [...prev, permission]
        );
    };

    const handleSubmit = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);

        try {
            let userId = user?.id;

            if (!userId) {
                // Use a temporary client for signUp to avoid signing out the admin
                // This ensures the current admin session remains active for the subsequent permission insertion
                const tempClient = createTempClient();
                const { data: authData, error: authError } = await tempClient.auth.signUp({
                    email,
                    password,
                });

                if (authError) throw authError;
                userId = authData.user?.id;
            }


            if (!userId) throw new Error("Falha ao obter ID do usuário");

            // Update permissions
            // Update permissions using Diff logic to avoid self-lockout
            // 1. Identify what to add and what to remove
            const currentPermissions = user ? user.permissions : [];
            const permissionsToAdd = selectedPermissions.filter(
                (p) => !currentPermissions.includes(p)
            );
            const permissionsToRemove = currentPermissions.filter(
                (p) => !selectedPermissions.includes(p)
            );

            // 2. Perform INSERTs first (ADD permissions)
            if (permissionsToAdd.length > 0) {
                const { error: insertError } = await supabase
                    .from("user_permissions" as any)
                    .insert(
                        permissionsToAdd.map((p) => ({
                            user_id: userId,
                            permission: p,
                        }))
                    );

                if (insertError) throw insertError;
            }

            // 3. Perform DELETEs last (REMOVE permissions)
            if (permissionsToRemove.length > 0) {
                const { error: deleteError } = await supabase
                    .from("user_permissions" as any)
                    .delete()
                    .eq("user_id", userId)
                    .in("permission", permissionsToRemove);

                if (deleteError) throw deleteError;
            }

            toast.success(user ? "Usuário atualizado!" : "Usuário criado!");
            onSuccess();
            onOpenChange(false);
        } catch (error: any) {
            toast.error(error.message || "Erro ao salvar usuário");
        } finally {
            setLoading(false);
        }
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="sm:max-w-md">
                <DialogHeader>
                    <DialogTitle>{user ? "Editar Usuário" : "Novo Usuário"}</DialogTitle>
                </DialogHeader>
                <form onSubmit={handleSubmit} className="space-y-4 py-4">
                    <div className="space-y-2">
                        <Label htmlFor="email">E-mail</Label>
                        <Input
                            id="email"
                            type="email"
                            value={email}
                            onChange={(e) => setEmail(e.target.value)}
                            disabled={!!user}
                            required
                        />
                    </div>
                    {!user && (
                        <div className="space-y-2">
                            <Label htmlFor="password">Senha</Label>
                            <Input
                                id="password"
                                type="password"
                                value={password}
                                onChange={(e) => setPassword(e.target.value)}
                                required
                            />
                        </div>
                    )}
                    <div className="space-y-3">
                        <div className="flex items-center justify-between">
                            <Label>Permissões</Label>
                            <Button
                                type="button"
                                variant="ghost"
                                size="sm"
                                className="h-auto px-2 py-1 text-xs"
                                onClick={() => {
                                    if (selectedPermissions.length === AVAILABLE_PERMISSIONS.length) {
                                        setSelectedPermissions([]);
                                    } else {
                                        setSelectedPermissions([...AVAILABLE_PERMISSIONS]);
                                    }
                                }}
                            >
                                {selectedPermissions.length === AVAILABLE_PERMISSIONS.length
                                    ? "Desmarcar todas"
                                    : "Selecionar todas"}
                            </Button>
                        </div>
                        <div className="grid gap-2">

                            {AVAILABLE_PERMISSIONS.map((permission) => (
                                <div key={permission} className="flex items-center space-x-2">
                                    <Checkbox
                                        id={`perm-${permission}`}
                                        checked={selectedPermissions.includes(permission)}
                                        onCheckedChange={() => handleTogglePermission(permission)}
                                    />
                                    <label
                                        htmlFor={`perm-${permission}`}
                                        className="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70"
                                    >
                                        {permission}
                                    </label>
                                </div>
                            ))}
                        </div>
                    </div>
                    <DialogFooter className="pt-4">
                        <Button type="button" variant="ghost" onClick={() => onOpenChange(false)}>
                            Cancelar
                        </Button>
                        <Button type="submit" disabled={loading}>
                            {loading ? "Salvando..." : "Salvar"}
                        </Button>
                    </DialogFooter>
                </form>
            </DialogContent>
        </Dialog>
    );
}
