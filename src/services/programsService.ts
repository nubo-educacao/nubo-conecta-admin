import { supabase } from '@/integrations/supabase/client';

export type ProgramType = 'sisu' | 'prouni';
export type ProgramStatus = 'incoming' | 'opened' | 'closed';

export interface Program {
  id: string;
  type: ProgramType;
  cycle_year: number;
  cycle_semester: string;
  title: string;
  description: string | null;
  status: ProgramStatus;
  redirect_url: string | null;
  starts_at: string | null;
  ends_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface ListProgramsOptions {
  type?: ProgramType | 'all';
  status?: ProgramStatus | 'all';
}

export async function listPrograms(options: ListProgramsOptions = {}): Promise<Program[]> {
  const { type = 'all', status = 'all' } = options;
  let query = supabase
    .from('programs')
    .select('*')
    .order('cycle_year', { ascending: false })
    .order('cycle_semester', { ascending: false });

  if (type !== 'all') {
    query = query.eq('type', type);
  }
  if (status !== 'all') {
    query = query.eq('status', status);
  }

  const { data, error } = await query;
  if (error) throw new Error(`listPrograms failed: ${error.message}`);
  return (data ?? []) as Program[];
}

export interface CreateProgramInput {
  type: ProgramType;
  cycle_year: number;
  cycle_semester: string;
  title: string;
  description?: string | null;
  status?: ProgramStatus;
  redirect_url?: string | null;
  starts_at?: string | null;
  ends_at?: string | null;
}

export async function createProgram(input: CreateProgramInput): Promise<Program> {
  const { data, error } = await supabase
    .from('programs')
    .insert({
      ...input,
      status: input.status ?? 'incoming',
    })
    .select()
    .single();

  if (error) throw new Error(`createProgram failed: ${error.message}`);
  return data as Program;
}

export type UpdateProgramInput = Partial<CreateProgramInput>;

export async function updateProgram(id: string, input: UpdateProgramInput): Promise<Program> {
  const { data, error } = await supabase
    .from('programs')
    .update(input)
    .eq('id', id)
    .select()
    .single();

  if (error) throw new Error(`updateProgram failed: ${error.message}`);
  return data as Program;
}

export async function updateProgramStatus(id: string, status: ProgramStatus): Promise<Program> {
  const { data, error } = await supabase
    .from('programs')
    .update({ status })
    .eq('id', id)
    .select()
    .single();

  if (error) throw new Error(`updateProgramStatus failed: ${error.message}`);
  return data as Program;
}

export async function deleteProgram(id: string): Promise<void> {
  const { error } = await supabase
    .from('programs')
    .delete()
    .eq('id', id);

  if (error) throw new Error(`deleteProgram failed: ${error.message}`);
}
