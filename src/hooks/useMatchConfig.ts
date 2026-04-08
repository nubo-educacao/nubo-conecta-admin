import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { 
  getMatchWeights, 
  updateMatchWeight,
  simulateMatchFrontend,
  SimulationInput,
  SimulationResult,
  MatchWeight
} from "../services/matchEngineService";
import { toast } from "sonner";
import { useState } from "react";

export const useMatchConfig = () => {
  const queryClient = useQueryClient();

  const query = useQuery({
    queryKey: ["match_config"],
    queryFn: getMatchWeights,
  });

  const updateMutation = useMutation({
    mutationFn: ({ id, value }: { id: string, value: number }) => updateMatchWeight(id, value),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["match_config"] });
      toast.success("Peso atualizado com sucesso.");
    },
    onError: (err) => {
      toast.error("Erro ao atualizar peso:" + err.message);
    }
  });

  return {
    weights: query.data || [],
    isLoading: query.isLoading,
    isError: query.isError,
    updateWeight: updateMutation.mutateAsync,
  };
};

export const useMatchSimulator = () => {
  const [simulationResults, setSimulationResults] = useState<SimulationResult[] | null>(null);
  const [isSimulating, setIsSimulating] = useState(false);

  const simulate = async (input: SimulationInput, weights: MatchWeight[]) => {
    setIsSimulating(true);
    try {
      const results = await simulateMatchFrontend(input, weights);
      setSimulationResults(results);
      toast.success(`Simulação concluída: ${results.length} resultados gerados.`);
    } catch (err: any) {
      toast.error("Erro na simulação: " + err.message);
      setSimulationResults(null);
    } finally {
      setIsSimulating(false);
    }
  };

  return {
    simulationResults,
    isSimulating,
    simulate
  };
};
