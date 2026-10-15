import React from "react";
import { useAuth } from "@/context/AuthContext";
import { SNAPS_PROJECT_ID, SNAPS_PROXY_URL } from "@/lib/snapsProxyClient";

export default function Roadmap() {
  // NUB-RD-86 (A4): o componente fala com o proxy do admin e se identifica
  // com o token da sessão; a chave do Snaps fica só no servidor.
  const { session } = useAuth();

  return (
    <div className="flex-1 space-y-4 p-8 pt-6 animate-in fade-in slide-in-from-bottom-2">
      <div className="flex items-center justify-between">
        <h2 className="text-3xl font-bold tracking-tight">Roadmap</h2>
        <span className="text-sm text-muted-foreground">
          Visualização somente leitura
        </span>
      </div>

      <snaps-roadmap-board
        project-id={SNAPS_PROJECT_ID}
        api-key={session?.access_token ?? ""}
        api-url={SNAPS_PROXY_URL}
      />
    </div>
  );
}
