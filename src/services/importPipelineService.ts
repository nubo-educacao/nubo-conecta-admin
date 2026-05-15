// importPipelineService — Sprint 02 Wave 5
// Orchestrates the two-step MEC CSV import flow:
//   1. generateUploadUrl → calls generate-upload-url Edge Function → returns signed URL
//   2. triggerImport     → calls import-mec-data Edge Function → returns { processed, errors }
// PLAYBOOK § 3: supabase client from integrations (not raw fetch) for auth header injection.

import { supabase } from '@/integrations/supabase/client';

export type ImportType =
  | 'institutions'
  | 'campus'
  | 'courses'
  | 'sisu_vacancies'
  | 'sisu_approvals'
  | 'prouni_vacancies';

interface GenerateUploadUrlResult {
  signedUrl: string;
  path: string;
}

interface TriggerImportResult {
  processed: number;
  errors: string[];
}

/**
 * Calls the generate-upload-url Edge Function to get a signed URL for direct upload.
 * @param filename - Original filename (used for storage path construction)
 * @returns { signedUrl, path } — use signedUrl for the PUT request, path for triggerImport
 * @throws Error if the Edge Function call fails
 */
export async function generateUploadUrl(filename: string): Promise<GenerateUploadUrlResult> {
  const { data, error } = await supabase.functions.invoke('generate-upload-url', {
    body: { filename, bucket: 'mec-csv-uploads' },
  });

  if (error) {
    throw new Error(`generateUploadUrl failed: ${error.message}`);
  }

  if (!data?.signedUrl || !data?.path) {
    throw new Error('generateUploadUrl: invalid response from Edge Function');
  }

  return { signedUrl: data.signedUrl, path: data.path };
}

const ETL_FUNCTION_MAP: Partial<Record<ImportType, string>> = {
  prouni_vacancies: 'import-prouni-vacancies',
  sisu_approvals:   'import-sisu-approvals',
  sisu_vacancies:   'import-sisu-vacancies',
};

/**
 * Triggers an ETL Edge Function for data-layer normalization (no CSV upload required).
 * Used for prouni_vacancies, sisu_approvals, sisu_vacancies.
 * @param importType - ETL type
 * @param params     - Optional params (e.g. { year: 2026 } for sisu_approvals)
 */
export async function triggerEtl(
  importType: 'prouni_vacancies' | 'sisu_approvals' | 'sisu_vacancies',
  params?: Record<string, unknown>,
): Promise<TriggerImportResult> {
  const fnName = ETL_FUNCTION_MAP[importType];
  if (!fnName) throw new Error(`No ETL function mapped for: ${importType}`);

  const { data, error } = await supabase.functions.invoke(fnName, {
    body: params ?? {},
  });

  if (error) {
    throw new Error(`triggerEtl failed [${importType}]: ${error.message}`);
  }

  return {
    processed: data?.processed ?? 0,
    errors:    data?.errors    ?? [],
  };
}

/**
 * Triggers the import-mec-data Edge Function to process an already-uploaded file.
 * @param fileKey    - Storage path returned by generateUploadUrl
 * @param importType - Entity type to import (institutions | campus | courses)
 * @returns { processed, errors } — summary of import results
 * @throws Error if the Edge Function call fails
 */
export async function triggerImport(
  fileKey: string,
  importType: ImportType,
): Promise<TriggerImportResult> {
  const { data, error } = await supabase.functions.invoke('import-mec-data', {
    body: { fileKey, importType },
  });

  if (error) {
    throw new Error(`triggerImport failed [${importType}]: ${error.message}`);
  }

  return {
    processed: data?.processed ?? 0,
    errors:    data?.errors    ?? [],
  };
}
