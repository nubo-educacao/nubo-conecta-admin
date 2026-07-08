import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { fetchActivePrograms, fetchEtlLogs, triggerEtlStep, EtlStepType, fetchAllEtlLogs, rollbackEtlStep, updateProgramPrevCycle, triggerCloneCycle, stopEtlStep } from '@/services/etlPipelineService';
import { toast } from 'sonner';

export function useActivePrograms() {
  return useQuery({
    queryKey: ['active-programs'],
    queryFn: fetchActivePrograms,
  });
}

export function useEtlLogs(programId: string | null) {
  return useQuery({
    queryKey: ['etl-logs', programId],
    queryFn: () => fetchEtlLogs(programId!),
    enabled: !!programId,
    refetchInterval: 5000, // Auto-refresh while looking
  });
}

export function useAllEtlLogs(page: number, pageSize: number) {
  return useQuery({
    queryKey: ['etl-logs-all', page, pageSize],
    queryFn: () => fetchAllEtlLogs(page, pageSize),
    refetchInterval: 5000,
  });
}

export function useTriggerEtlStep() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ step, programId, onProgress }: { step: EtlStepType; programId?: string; onProgress?: (processed: number, total: number) => void }) => 
      triggerEtlStep(step, programId, onProgress),
    onSuccess: (data, variables) => {
      toast.success(`Passo ${variables.step} concluído com sucesso!`, {
        description: `${data.processed} registros processados.`,
      });
      queryClient.invalidateQueries({ queryKey: ['etl-logs', variables.programId] });
      queryClient.invalidateQueries({ queryKey: ['etl-logs-all'] });
    },
    onError: (error: any, variables) => {
      toast.error(`Erro ao executar ${variables.step}`, {
        description: error.message,
      });
      queryClient.invalidateQueries({ queryKey: ['etl-logs', variables.programId] });
      queryClient.invalidateQueries({ queryKey: ['etl-logs-all'] });
    },
  });
}

export function useStopEtlStep() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ logId }: { logId: string }) => stopEtlStep(logId),
    onSuccess: (data) => {
      toast.success('Execução parada com sucesso!', {
        description: data.pid_cancelled ? 'O processo no banco de dados foi interrompido.' : 'Apenas o status foi atualizado (nenhum processo em andamento).',
      });
      queryClient.invalidateQueries({ queryKey: ['etl-logs'] });
      queryClient.invalidateQueries({ queryKey: ['etl-logs-all'] });
    },
    onError: (error: any) => {
      toast.error('Erro ao parar a execução', {
        description: error.message,
      });
    },
  });
}

export function useRollbackEtlStep() {
  const queryClient = useQueryClient();
  const [rollbackProgress, setRollbackProgress] = useState<{ logId: string; processed: number } | null>(null);

  const mutation = useMutation({
    mutationFn: ({ logId }: { logId: string }) =>
      rollbackEtlStep(logId, (processed) => {
        setRollbackProgress({ logId, processed });
      }),
    onSuccess: (data) => {
      setRollbackProgress(null);
      toast.success(`Rollback concluído com sucesso!`, {
        description: `${data.processed.toLocaleString('pt-BR')} registros removidos.`,
      });
      queryClient.invalidateQueries({ queryKey: ['etl-logs'] });
      queryClient.invalidateQueries({ queryKey: ['etl-logs-all'] });
      queryClient.invalidateQueries({ queryKey: ['institutions'] });
    },
    onError: (error: any) => {
      setRollbackProgress(null);
      toast.error(`Erro ao executar rollback`, {
        description: error.message,
      });
      queryClient.invalidateQueries({ queryKey: ['etl-logs'] });
      queryClient.invalidateQueries({ queryKey: ['etl-logs-all'] });
    },
  });

  return { ...mutation, rollbackProgress };
}

export function useUpdatePrevCycle() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ programId, prevProgramId }: { programId: string; prevProgramId: string | null }) =>
      updateProgramPrevCycle(programId, prevProgramId),
    onSuccess: () => {
      toast.success('Ciclo anterior atualizado com sucesso!');
      queryClient.invalidateQueries({ queryKey: ['active-programs'] });
    },
    onError: (error: any) => {
      toast.error('Erro ao atualizar ciclo anterior', {
        description: error.message,
      });
    },
  });
}

export function useCloneCycle() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ sourceProgramId, targetProgramId }: { sourceProgramId: string; targetProgramId: string }) =>
      triggerCloneCycle(sourceProgramId, targetProgramId),
    onSuccess: (data) => {
      toast.success('Ciclo clonado com sucesso!', {
        description: `${data.opp_cloned} oportunidades e ${data.vac_cloned} vagas clonadas.`,
      });
      queryClient.invalidateQueries({ queryKey: ['active-programs'] });
      queryClient.invalidateQueries({ queryKey: ['etl-logs'] });
      queryClient.invalidateQueries({ queryKey: ['etl-logs-all'] });
    },
    onError: (error: any) => {
      toast.error('Erro ao clonar ciclo', {
        description: error.message,
      });
    },
  });
}
