import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { 
  getCloudinhaStarters, 
  upsertCloudinhaStarter, 
  deleteCloudinhaStarter,
  getAgentPrompts,
  updateAgentPrompt,
  CloudinhaStarter,
  AgentPrompt
} from "../services/agentConfigService";
import { toast } from "sonner";

export const useCloudinhaStarters = () => {
  const queryClient = useQueryClient();

  const query = useQuery({
    queryKey: ["cloudinha_starters"],
    queryFn: getCloudinhaStarters,
  });

  const upsertMutation = useMutation({
    mutationFn: upsertCloudinhaStarter,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["cloudinha_starters"] });
      toast.success("Starter salvo com sucesso.");
    },
    onError: (err) => {
      toast.error("Erro ao salvar starter:" + err.message);
    }
  });

  const deleteMutation = useMutation({
    mutationFn: deleteCloudinhaStarter,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["cloudinha_starters"] });
      toast.success("Starter excluído com sucesso.");
    },
    onError: (err) => {
      toast.error("Erro ao excluir starter:" + err.message);
    }
  });

  return {
    starters: query.data || [],
    isLoading: query.isLoading,
    isError: query.isError,
    upsertStarter: upsertMutation.mutateAsync,
    deleteStarter: deleteMutation.mutateAsync,
  };
};

export const useAgentPrompts = () => {
  const queryClient = useQueryClient();

  const query = useQuery({
    queryKey: ["agent_prompts"],
    queryFn: getAgentPrompts,
  });

  const updateMutation = useMutation({
    mutationFn: ({ id, data }: { id: string, data: Partial<AgentPrompt> }) => updateAgentPrompt(id, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["agent_prompts"] });
      toast.success("Prompt do agente salvo com sucesso.");
    },
    onError: (err) => {
      toast.error("Erro ao salvar prompt:" + err.message);
    }
  });

  return {
    prompts: query.data || [],
    isLoading: query.isLoading,
    isError: query.isError,
    updatePrompt: updateMutation.mutateAsync,
  };
};
