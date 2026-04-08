import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';

export type IssueInput = {
  application: string;
  version: string;
  title: string;
  type: string;
  body: string;
};

export const useGetIssues = () => {
  return useQuery({
    queryKey: ['github-issues'],
    queryFn: async () => {
      const { data, error } = await supabase.functions.invoke('github-proxy?repo=nubo-conecta-admin', {
        method: 'GET',
      });
      if (error) throw error;
      return data;
    },
  });
};

export const useCreateIssue = () => {
  return useMutation({
    mutationFn: async (issueParams: IssueInput) => {
      const { data, error } = await supabase.functions.invoke('github-proxy', {
        method: 'POST',
        body: issueParams,
      });
      if (error) throw error;
      return data;
    },
  });
};

export type IssueStatusUpdate = {
  issueNumber: number;
  repo: string;
  action: 'abrir' | 'aprovar' | 'concluir';
};

export const useUpdateIssueStatus = () => {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (params: IssueStatusUpdate) => {
      const { data, error } = await supabase.functions.invoke('github-proxy', {
        method: 'PATCH',
        body: params,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['github-issues'] });
    },
  });
};
