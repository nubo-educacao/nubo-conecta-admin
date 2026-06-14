import { supabase } from '@/integrations/supabase/client';

export type EtlStepType =
  | 'prouni_base'
  | 'prouni_vacancies'
  | 'prouni_occupied'
  | 'sisu'
  | 'sisu_vacancies'
  | 'emec'
  | 'refresh_opportunities'
  | 'refresh_catalog';

export interface EtlRunLog {
  id: string;
  program_id: string;
  etl_type: EtlStepType;
  status: 'running' | 'success' | 'error';
  records_processed: number;
  errors: string | null;
  started_at: string;
  finished_at: string | null;
  user_id: string | null;
  user_name: string | null;
}

export interface Program {
  id: string;
  title: string;
  cycle_year: number;
  cycle_semester: string;
  status: 'incoming' | 'opened' | 'closed' | 'inactive';
  type: 'sisu' | 'prouni';
  prev_program_id: string | null;
  is_fully_imported: boolean;
}

/**
 * Fetches all programs
 */
export async function fetchActivePrograms(): Promise<Program[]> {
  const { data, error } = await supabase
    .from('programs')
    .select('*')
    .order('created_at', { ascending: false });

  if (error) {
    throw new Error(`Failed to fetch programs: ${error.message}`);
  }

  return data as Program[];
}

/**
 * Updates the prev_program_id for a given program
 */
export async function updateProgramPrevCycle(programId: string, prevProgramId: string | null): Promise<void> {
  const { error } = await supabase
    .from('programs')
    .update({ prev_program_id: prevProgramId })
    .eq('id', programId);

  if (error) {
    throw new Error(`Failed to update previous cycle: ${error.message}`);
  }
}

/**
 * Fetches ETL logs for a specific program
 */
export async function fetchEtlLogs(programId: string): Promise<EtlRunLog[]> {
  const { data, error } = await supabase
    .from('etl_run_logs')
    .select('*')
    .eq('program_id', programId)
    // DESC so the most recent run per etl_type is found first by Array.find()
    .order('started_at', { ascending: false });

  if (error) {
    throw new Error(`Failed to fetch ETL logs: ${error.message}`);
  }

  return data as EtlRunLog[];
}

export async function triggerEtlStep(
  step: EtlStepType,
  programId?: string,
  onProgress?: (processed: number, total: number) => void
): Promise<{ processed: number; errors: string[] }> {
  const rpcName = `etl_import_${step}`;
  
  // EMEC and refreshes do not need program_id
  const needsProgramId = !['emec', 'refresh_opportunities', 'refresh_catalog'].includes(step);
  const isBatched = !['refresh_opportunities', 'refresh_catalog'].includes(step);

  if (isBatched) {
    let hasMore = true;
    let offset = 0;
    const limit = 5000;
    let totalProcessed = 0;
    let logId: string | undefined = undefined;
    let allErrors: string[] = [];
    let totalRawRows = 0;

    while (hasMore) {
      const params: any = { p_limit: limit, p_offset: offset };
      if (programId && needsProgramId) params.p_program_id = programId;
      if (logId) params.p_log_id = logId;

      const { data, error } = await supabase.rpc(rpcName, params);

      if (error) {
        throw new Error(`ETL Step [${step}] failed at offset ${offset}: ${error.message}`);
      }
      if (data?.status === 'error') {
        const msg = typeof data.errors === 'string' ? data.errors : JSON.stringify(data.errors);
        throw new Error(msg || `ETL Step [${step}] returned an error status at offset ${offset}.`);
      }

      const batchProcessed = data?.processed ?? data?.opportunities_processed ?? data?.vacancies_processed ?? 0;
      totalProcessed += batchProcessed;
      
      hasMore = data?.has_more === true;
      logId = data?.log_id;
      totalRawRows = data?.total_raw_rows ?? totalRawRows;
      
      offset += limit;

      if (onProgress && totalRawRows > 0) {
        // Passa a quantidade de linhas brutas percorridas vs o total do CSV para o cálculo da porcentagem.
        // Na última volta (hasMore = false), o offset pode estourar o totalRawRows, então travamos no 100%.
        const processedRaw = Math.min(offset, totalRawRows);
        onProgress(processedRaw, totalRawRows);
      } else if (onProgress && !hasMore) {
        onProgress(1, 1); // 100% fallback caso totalRawRows seja 0
      }

      if (data?.errors) {
        const errs = Array.isArray(data.errors) ? data.errors : [data.errors];
        // Don't treat the final success message as an error array item
        allErrors = [...allErrors, ...errs.filter((e: string) => e && !e.includes('sucesso'))];
      }
    }

    return { processed: totalProcessed, errors: allErrors };
  }

  // Normal steps (refreshes)
  const params = programId && needsProgramId ? { p_program_id: programId } : undefined;
  
  const { data, error } = await supabase.rpc(rpcName, params);

  // Network / PostgREST error
  if (error) {
    throw new Error(`ETL Step [${step}] failed: ${error.message}`);
  }

  // The RPC may return { status: 'error', errors: '...' } with HTTP 200.
  // Treat this as a real failure so onError toast fires.
  if (data?.status === 'error') {
    const msg = typeof data.errors === 'string' ? data.errors : JSON.stringify(data.errors);
    throw new Error(msg || `ETL Step [${step}] returned an error status.`);
  }

  return {
    processed: data?.processed ?? data?.opportunities_processed ?? data?.vacancies_processed ?? 0,
    errors: data?.errors ?? [],
  };
}

export interface EtlRunLogWithProgram extends EtlRunLog {
  programs: {
    title: string;
    cycle_year: number;
    cycle_semester: string;
    status: 'incoming' | 'opened' | 'closed' | 'inactive';
  } | null;
}

export async function fetchAllEtlLogs(page: number, pageSize: number): Promise<{ data: EtlRunLogWithProgram[]; count: number }> {
  const from = page * pageSize;
  const to = from + pageSize - 1;

  const { data, error, count } = await supabase
    .from('etl_run_logs')
    .select('*, programs(title, cycle_year, cycle_semester, status)', { count: 'exact' })
    .order('started_at', { ascending: false })
    .range(from, to);

  if (error) {
    throw new Error(`Failed to fetch ETL logs: ${error.message}`);
  }

  return {
    data: data as EtlRunLogWithProgram[],
    count: count ?? 0,
  };
}

/**
 * Rolls back an ETL step by deleting inserted records in batches
 */
export async function rollbackEtlStep(
  logId: string,
  onProgress?: (processed: number) => void
): Promise<{ status: string; message: string; processed: number }> {
  let hasMore = true;
  let activeRollbackId: string | undefined = undefined;
  let totalProcessed = 0;

  while (hasMore) {
    const params: any = { p_log_id: logId, p_limit: 500 };
    if (activeRollbackId) {
      params.p_active_rollback_id = activeRollbackId;
    }

    const { data, error } = await supabase.rpc('etl_rollback_log', params);

    if (error) {
      throw new Error(`Rollback failed at batch: ${error.message}`);
    }

    if (data?.status === 'error') {
      const msg = typeof data.errors === 'string' ? data.errors : JSON.stringify(data.errors);
      throw new Error(msg || 'Rollback returned an error status.');
    }

    hasMore = data?.has_more === true;
    activeRollbackId = data?.log_id;
    const batchProcessed = data?.processed ?? 0;
    totalProcessed += batchProcessed;

    if (onProgress) {
      onProgress(totalProcessed);
    }
  }

  return {
    status: 'success',
    message: 'Rollback completed successfully in batches',
    processed: totalProcessed,
  };
}
