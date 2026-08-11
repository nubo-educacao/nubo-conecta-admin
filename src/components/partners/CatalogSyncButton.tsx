import { useMutation } from "@tanstack/react-query";
import { Loader2, RefreshCw } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/context/AuthContext";
import { triggerEtlStep } from "@/services/etlPipelineService";

const CATALOG_SYNC_TOAST_ID = "catalog-sync";

export function CatalogSyncButton() {
  const { userRole } = useAuth();
  const syncMutation = useMutation({
    mutationFn: () => triggerEtlStep("refresh_opportunities"),
    onMutate: () => {
      toast.loading("Sincronizando catálogo...", {
        id: CATALOG_SYNC_TOAST_ID,
      });
    },
    onSuccess: () => {
      toast.success("Catálogo sincronizado com sucesso!", {
        id: CATALOG_SYNC_TOAST_ID,
      });
    },
    onError: (error: Error) => {
      toast.error("Erro ao sincronizar catálogo.", {
        id: CATALOG_SYNC_TOAST_ID,
        description: error.message,
      });
    },
  });

  if (userRole === "partner") {
    return null;
  }

  return (
    <Button
      type="button"
      variant="outline"
      className="gap-2"
      disabled={syncMutation.isPending}
      onClick={() => syncMutation.mutate()}
    >
      {syncMutation.isPending ? (
        <Loader2 className="h-4 w-4 animate-spin" />
      ) : (
        <RefreshCw className="h-4 w-4" />
      )}
      {syncMutation.isPending ? "Sincronizando..." : "Sincronizar Catálogo"}
    </Button>
  );
}
