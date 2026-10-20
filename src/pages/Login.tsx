import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { Loader2 } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { loginErrorMessage } from "@/lib/loginErrors";
import { LoginArt } from "./login/LoginArt";

const ERROR_ID = "login-error";

export default function Login() {
    const [email, setEmail] = useState("");
    const [password, setPassword] = useState("");
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const navigate = useNavigate();

    const handleLogin = async (e: React.FormEvent) => {
        e.preventDefault();
        setError(null);
        setLoading(true);

        try {
            const { data, error: authError } = await supabase.auth.signInWithPassword({
                email,
                password,
            });

            if (authError) throw authError;

            // Role-based redirect
            const role = data.user?.role;
            toast.success("Autenticado com sucesso!");

            if (role === "partner") {
                navigate("/partner");
            } else {
                navigate("/");
            }
        } catch (err: unknown) {
            setError(loginErrorMessage(err));
        } finally {
            setLoading(false);
        }
    };

    const describedBy = error ? ERROR_ID : undefined;

    return (
        <div className="grid h-dvh grid-rows-[6rem_minmax(0,1fr)] overflow-hidden bg-white lg:grid-cols-2 lg:grid-rows-[minmax(0,1fr)]">
            <main className="relative z-10 row-start-2 flex min-h-0 items-center justify-center overflow-y-auto px-6 py-6 lg:row-start-1 lg:py-12">
                <div className="my-auto w-full max-w-sm shrink-0">
                    <img
                        src="/brand/nubo-logo-sm.png"
                        alt="Nubo Conecta"
                        width={480}
                        height={274}
                        className="mx-auto h-16 w-auto"
                    />
                    <h1 className="mt-6 text-center font-display text-2xl font-bold text-slate-900">
                        Nubo Conecta Admin
                    </h1>
                    <p className="mt-1 text-center text-sm text-slate-600">
                        Entre com suas credenciais de backoffice
                    </p>

                    <form onSubmit={handleLogin} className="mt-8 space-y-5">
                        <div className="space-y-2">
                            <Label htmlFor="email" className="text-slate-800">E-mail</Label>
                            <Input
                                id="email"
                                name="email"
                                type="email"
                                autoComplete="email"
                                placeholder="seu@email.com"
                                value={email}
                                onChange={(e) => { setEmail(e.target.value); setError(null); }}
                                aria-invalid={error ? true : undefined}
                                aria-describedby={describedBy}
                                required
                            />
                        </div>
                        <div className="space-y-2">
                            <Label htmlFor="password" className="text-slate-800">Senha</Label>
                            <Input
                                id="password"
                                name="password"
                                type="password"
                                autoComplete="current-password"
                                value={password}
                                onChange={(e) => { setPassword(e.target.value); setError(null); }}
                                aria-invalid={error ? true : undefined}
                                aria-describedby={describedBy}
                                required
                            />
                        </div>

                        {error && (
                            <p
                                id={ERROR_ID}
                                role="alert"
                                className="rounded-md border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800"
                            >
                                {error}
                            </p>
                        )}

                        <Button
                            type="submit"
                            size="lg"
                            className="w-full bg-[#024F86] text-white hover:bg-[#013B66] focus-visible:ring-[#3092bb]"
                            disabled={loading}
                            aria-busy={loading}
                        >
                            {loading ? (
                                <>
                                    <Loader2 className="animate-spin motion-reduce:animate-none" aria-hidden="true" />
                                    Entrando...
                                </>
                            ) : (
                                "Entrar"
                            )}
                        </Button>
                    </form>
                </div>
            </main>

            <LoginArt className="relative col-start-1 row-start-1 min-h-0 rounded-b-3xl lg:col-start-2 lg:rounded-none" />
        </div>
    );
}
