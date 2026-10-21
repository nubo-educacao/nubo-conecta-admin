import { supabase } from '@/integrations/supabase/client';
import { attributionRpcArgs, type AttributionFilter } from '@/lib/attributionFilter';
import type { UserMatch } from './studentsService';
import type { ApplicationWithDetails } from './applicationsService';

export const ACTIVITY_PAGE_SIZE = 20;
export interface ActivityPage<T> { data: T[]; count: number }
export interface StudentClick {
  id: string;
  event_type: string;
  occurred_at: string;
  entity_name: string | null;
  entity_type: string;
  entity_id: string;
  unified_opportunity_id: string | null;
  destination_url: string | null;
  event_count: number;
  source: string | null;
}
export type ActivityApplication = Pick<ApplicationWithDetails,
  'id' | 'user_id' | 'partner_id' | 'partner_name' | 'institution_name' |
  'status' | 'created_at' | 'eligibility_results'>;

function validateRequest(studentId: string, page: number) {
  if (!studentId || !Number.isSafeInteger(page) || page < 0) throw new Error('Consulta de atividade inválida.');
}
function resultPage<T>(data: T[] | null, count: number | null | undefined): ActivityPage<T> {
  if (!Array.isArray(data) || !Number.isSafeInteger(count) || count! < 0) {
    throw new Error('Resposta de atividade incompleta.');
  }
  return { data, count: count! };
}

export async function getActivityMatches(studentId: string, page: number): Promise<ActivityPage<UserMatch>> {
  validateRequest(studentId, page);
  const { data, error } = await supabase.rpc('get_student_matches_admin_page' as any,
    { p_profile_id: studentId, p_page: page, p_page_size: ACTIVITY_PAGE_SIZE });
  if (error) throw error;
  const response = data as unknown as { matches: UserMatch[]; count: number } | null;
  return resultPage(response?.matches ?? null, response?.count);
}

export async function getActivityClicks(studentId: string, page: number): Promise<ActivityPage<StudentClick>> {
  validateRequest(studentId, page);
  const { data, error } = await supabase.rpc('get_student_clicks_admin' as any,
    { p_user_id: studentId, p_page: page, p_page_size: ACTIVITY_PAGE_SIZE });
  if (error) throw error;
  const response = data as unknown as ActivityPage<StudentClick> | null;
  return resultPage(response?.data ?? null, response?.count);
}

/** PostgREST filters/count/range apply on the server to the table-valued RPC.
 * Keep the existing SQL signature, guard and first-touch filters unchanged.
 * An exact count is independent of the selected page, including an empty page.
 */
export async function getActivityApplications(
  studentId: string, page: number, attribution: AttributionFilter = {},
): Promise<ActivityPage<ActivityApplication>> {
  validateRequest(studentId, page);
  const { data, count, error } = await supabase
    .rpc('get_student_applications_with_details', attributionRpcArgs(attribution), { count: 'exact' })
    .select('id,user_id,partner_id,partner_name,institution_name,status,created_at,eligibility_results')
    .eq('user_id', studentId)
    .order('created_at', { ascending: false })
    .order('id', { ascending: true })
    .range(page * ACTIVITY_PAGE_SIZE, (page + 1) * ACTIVITY_PAGE_SIZE - 1);
  if (error) throw error;
  return resultPage(data as unknown as ActivityApplication[] | null, count);
}
