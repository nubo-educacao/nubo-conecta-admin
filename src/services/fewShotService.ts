import { supabase } from '@/integrations/supabase/client';

// Canonical contract shared with the agent. Starter/tools/order are not columns.
export interface FewShotExample {
  id: string;
  intent_category: string | null;
  input_query: string;
  ideal_output: string;
  reasoning: string | null;
  source: string | null;
  is_active: boolean | null;
  created_at: string | null;
}
export type CreateFewShotDTO = Pick<FewShotExample,
  'intent_category' | 'input_query' | 'ideal_output' | 'reasoning' | 'is_active'>;
const columns = 'id,intent_category,input_query,ideal_output,reasoning,source,is_active,created_at';

export async function getFewShotExamples(): Promise<FewShotExample[]> {
  const { data, error } = await supabase.from('learning_examples')
    .select(columns).order('created_at', { ascending: false });
  if (error) throw error;
  return data ?? [];
}
export async function createFewShotExample(dto: CreateFewShotDTO): Promise<FewShotExample> {
  const { data, error } = await supabase.from('learning_examples')
    .insert({ ...dto, source: 'admin' }).select(columns).single();
  if (error) throw error;
  return data;
}
export async function updateFewShotExample(id: string, dto: Partial<CreateFewShotDTO>): Promise<void> {
  const { error } = await supabase.from('learning_examples').update(dto).eq('id', id);
  if (error) throw error;
}
export async function deleteFewShotExample(id: string): Promise<void> {
  const { error } = await supabase.from('learning_examples').delete().eq('id', id);
  if (error) throw error;
}
