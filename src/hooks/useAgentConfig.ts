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
import {
  getLearningExamples,
  createLearningExample,
  updateLearningExample,
  deleteLearningExample,
  CreateLearningExampleDTO,
} from "../services/fewShotService";
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

export const useLearningExamples = () => {
  const queryClient = useQueryClient();

  const query = useQuery({
    queryKey: ["learning_examples"],
    queryFn: getLearningExamples,
  });

  const createMutation = useMutation({
    mutationFn: (dto: CreateLearningExampleDTO) => createLearningExample(dto),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["learning_examples"] });
      toast.success("Learning example criado com sucesso.");
    },
    onError: (err: Error) => {
      toast.error("Erro ao criar example: " + err.message);
    },
  });

  const updateMutation = useMutation({
    mutationFn: ({ id, dto }: { id: string; dto: Partial<CreateLearningExampleDTO> }) =>
      updateLearningExample(id, dto),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["learning_examples"] });
      toast.success("Learning example atualizado.");
    },
    onError: (err: Error) => {
      toast.error("Erro ao atualizar example: " + err.message);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: deleteLearningExample,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["learning_examples"] });
      toast.success("Learning example excluído.");
    },
    onError: (err: Error) => {
      toast.error("Erro ao excluir example: " + err.message);
    },
  });

  return {
    examples: query.data || [],
    isLoading: query.isLoading,
    isError: query.isError,
    createExample: createMutation.mutateAsync,
    updateExample: updateMutation.mutateAsync,
    deleteExample: deleteMutation.mutateAsync,
  };
};
