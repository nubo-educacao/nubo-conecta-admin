import React, { createContext, useContext, useEffect, useRef, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Session, User } from "@supabase/supabase-js";
import { toast } from "sonner";

interface AuthContextType {
    session: Session | null;
    user: User | null;
    userRole: string | null;
    permissions: string[];
    loading: boolean;
    signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export const AuthProvider = ({ children }: { children: React.ReactNode }) => {
    const [session, setSession] = useState<Session | null>(null);
    const [user, setUser] = useState<User | null>(null);
    const [userRole, setUserRole] = useState<string | null>(null);
    const [permissions, setPermissions] = useState<string[]>([]);
    const [loading, setLoading] = useState(true);

    // Track whether the initial permissions load has completed.
    // Once true, we NEVER show the full-screen spinner again to avoid
    // unmounting the entire layout (which destroys modals and unsaved state).
    const hasInitiallyLoadedRef = useRef(false);

    useEffect(() => {
        console.log("AuthContext: Inicializando...");

        // Get initial session
        supabase.auth.getSession().then(({ data: { session } }) => {
            console.log("AuthContext: Sessão inicial obtida", session?.user?.id);
            setSession(session);
            setUser(session?.user ?? null);
            setUserRole(session?.user?.role ?? null);
            if (session?.user) {
                fetchPermissions(session.user.id);
            } else {
                hasInitiallyLoadedRef.current = true;
                setLoading(false);
            }
        });

        // Listen for auth changes
        const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
            console.log("AuthContext: Evento de Auth", event, session?.user?.id);
            setSession(session);
            setUser(session?.user ?? null);
            setUserRole(session?.user?.role ?? null);
            if (session?.user) {
                // After initial load, all subsequent fetches are silent background refreshes.
                fetchPermissions(session.user.id);
            } else {
                setPermissions([]);
                setLoading(false);
            }
        });

        return () => subscription.unsubscribe();
    }, []);

    const fetchPermissions = async (userId: string) => {
        const isInitialLoad = !hasInitiallyLoadedRef.current;
        console.log("AuthContext: Buscando permissões para", userId, "initial:", isInitialLoad);

        // Only show the full-screen spinner on the very first load.
        // After that, silently refresh in the background (no UI disruption).
        if (isInitialLoad) {
            setLoading(true);
        }

        try {
            // Add a timeout to prevent infinite hang
            const fetchPromise = supabase
                .from("user_permissions" as any)
                .select("permission")
                .eq("user_id", userId);

            const timeoutPromise = new Promise((_, reject) =>
                setTimeout(() => reject(new Error("Timeout ao buscar permissões")), 5000)
            );

            const { data, error }: any = await Promise.race([fetchPromise, timeoutPromise]);

            if (error) {
                console.error("AuthContext: Erro ao buscar permissões", error);
                throw error;
            }

            const userPerms = (data as any[] || []).map((p) => p.permission);
            console.log("AuthContext: Permissões recebidas", userPerms);

            setPermissions(userPerms);

            if (userPerms.length === 0 && userRole !== "partner") {
                console.warn("AuthContext: Usuário sem permissões detectado!");
                toast.error("Você não tem permissão para acessar o painel.");
            }
        } catch (error) {
            console.error("AuthContext: Erro capturado", error);
            setPermissions([]);
            toast.error("Erro ao carregar permissões");
        } finally {
            console.log("AuthContext: Finalizado carregamento");
            hasInitiallyLoadedRef.current = true;
            setLoading(false);
        }
    };

    const signOut = async () => {
        console.log("AuthContext: Realizando SignOut");
        await supabase.auth.signOut();
    };

    return (
        <AuthContext.Provider value={{ session, user, userRole, permissions, loading, signOut }}>
            {children}
        </AuthContext.Provider>
    );
};

export const useAuth = () => {
    const context = useContext(AuthContext);
    if (context === undefined) {
        throw new Error("useAuth must be used within an AuthProvider");
    }
    return context;
};
