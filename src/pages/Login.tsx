import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";

export default function Login() {
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [loading, setLoading] = useState(false);
    const navigate = useNavigate();

    const handleLogin = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);
        console.log("Login: Iniciando tentativa para", email);

        try {
            console.log("Login: Chamando signInWithPassword...");
            const { data, error } = await supabase.auth.signInWithPassword({
                email,
                password,
            });

            if (error) {
                console.error("Login: Erro no signInWithPassword", error);
                throw error;
            }

            console.log("Login: signInWithPassword sucesso!", data.user?.id);

            // Role-based redirect
            const role = data.user?.role;
            toast.success("Autenticado com sucesso!");

            if (role === "partner") {
                console.log("Login: Usuário parceiro, navegando para /partner");
                navigate("/partner");
            } else {
                console.log("Login: Usuário admin, navegando para /");
                navigate("/");
            }
        } catch (error: any) {
            console.error("Login: Erro capturado no catch", error);
            toast.error(error.message || "Erro ao realizar login");
        } finally {
            console.log("Login: Finalizado (finally)");
            setLoading(false);
        }
    };

    return (
        <div className="flex items-center justify-center min-h-screen bg-background">
            <Card className="w-full max-w-md shadow-lg border-primary/20">
                <CardHeader className="space-y-1">
                    <CardTitle className="text-2xl font-bold text-center">Nubo Hub Admin</CardTitle>
                    <CardDescription className="text-center">
                        Entre com suas credenciais de backoffice
                    </CardDescription>
                </CardHeader>
                <form onSubmit={handleLogin}>
                    <CardContent className="space-y-4">
                        <div className="space-y-2">
                            <Label htmlFor="email">E-mail</Label>
                            <Input
                                id="email"
                                type="email"
                                placeholder="seu@email.com"
                                value={email}
                                onChange={(e) => setEmail(e.target.value)}
                                required
                            />
                        </div>
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
                    </CardContent>
                    <CardFooter>
                        <Button type="submit" className="w-full" disabled={loading}>
                            {loading ? "Entrando..." : "Entrar"}
                        </Button>
                    </CardFooter>
                </form>
            </Card>
        </div>
    );
}
