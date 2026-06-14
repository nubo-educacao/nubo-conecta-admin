// partnerOpportunitiesService — Sprint 3.8
// CRUD for partner_opportunities table with institution join.
// Admin-only operations — RLS ensures only admin role users can write.

import { supabase } from '@/integrations/supabase/client';

export type OpportunityStatus = 'inactive' | 'incoming' | 'opened' | 'closed';
export type PartnerOpportunityType = 'programa de bolsa' | 'programa educacional';

export interface PartnerOpportunity {
  id: string;
  institution_id: string;
  institution_name?: string;
  name: string;
  description: string | null;
  opportunity_type: PartnerOpportunityType;
  category: string | null;
  eligibility_criteria: Record<string, unknown>;
  external_redirect_config: {
    enabled?: boolean;
    url?: string;
  };
  starts_at: string | null;
  ends_at: string | null;
  status: OpportunityStatus;
  created_at: string;
}

export interface ListPartnerOpportunitiesOptions {
  page?:   number;
  limit?:  number;
  status?: OpportunityStatus | 'all';
}

export interface ListPartnerOpportunitiesResult {
  data:  PartnerOpportunity[];
  count: number;
}

// --- Partner Institutions for Select dropdown ---
export interface PartnerInstitutionOption {
  id: string;
  name: string;
}

export async function listPartnerInstitutionsForSelect(): Promise<PartnerInstitutionOption[]> {
  const { data, error } = await supabase
    .from('institutions')
    .select('id, name')
    .eq('is_partner', true)
    .order('name');

  if (error) throw new Error(`listPartnerInstitutionsForSelect failed: ${error.message}`);
  return (data ?? []) as PartnerInstitutionOption[];
}

// --- LIST ---
export async function listPartnerOpportunities(
  options: ListPartnerOpportunitiesOptions = {},
): Promise<ListPartnerOpportunitiesResult> {
  const { page = 0, limit = 20, status = 'all' } = options;

  let query = supabase
    .from('partner_opportunities')
    .select(`
      *,
      institutions!inner ( name )
    `, { count: 'exact' })
    .order('created_at', { ascending: false })
    .range(page * limit, page * limit + limit - 1);

  if (status !== 'all') {
    query = query.eq('status', status);
  }

  const { data, error, count } = await query;

  if (error) throw new Error(`listPartnerOpportunities failed: ${error.message}`);

  const mapped = (data ?? []).map((row: any) => ({
    ...row,
    institution_name: row.institutions?.name ?? 'Desconhecida',
    institutions: undefined,
  }));

  return { data: mapped as PartnerOpportunity[], count: count ?? 0 };
}

// --- GET BY ID ---
export async function getPartnerOpportunityById(id: string): Promise<PartnerOpportunity> {
  const { data, error } = await supabase
    .from('partner_opportunities')
    .select('*')
    .eq('id', id)
    .single();

  if (error) throw new Error(`getPartnerOpportunityById failed: ${error.message}`);
  return data as PartnerOpportunity;
}

// --- CREATE ---
export interface CreatePartnerOpportunityInput {
  institution_id:          string;
  name:                    string;
  description?:            string;
  opportunity_type:        PartnerOpportunityType;
  category?:               string;
  eligibility_criteria?:   Record<string, unknown>;
  external_redirect_config?: { enabled?: boolean; url?: string };
  starts_at?: string | null;
  ends_at?: string | null;
}

export async function createPartnerOpportunity(
  input: CreatePartnerOpportunityInput,
): Promise<PartnerOpportunity> {
  const { data, error } = await supabase
    .from('partner_opportunities')
    .insert({
      ...input,
      eligibility_criteria: input.eligibility_criteria ?? {},
      external_redirect_config: input.external_redirect_config ?? {},
      status: 'inactive' as OpportunityStatus,
    })
    .select()
    .single();

  if (error) throw new Error(`createPartnerOpportunity failed: ${error.message}`);
  return data as PartnerOpportunity;
}

// --- UPDATE ---
export type UpdatePartnerOpportunityInput = Partial<CreatePartnerOpportunityInput>;

export async function updatePartnerOpportunity(
  id: string,
  input: UpdatePartnerOpportunityInput,
): Promise<PartnerOpportunity> {
  const { data, error } = await supabase
    .from('partner_opportunities')
    .update(input)
    .eq('id', id)
    .select()
    .single();

  if (error) throw new Error(`updatePartnerOpportunity failed: ${error.message}`);
  return data as PartnerOpportunity;
}

// --- UPDATE STATUS ---
export async function updatePartnerOpportunityStatus(
  id: string,
  status: OpportunityStatus,
): Promise<PartnerOpportunity> {
  const { data, error } = await supabase
    .from('partner_opportunities')
    .update({ status })
    .eq('id', id)
    .select()
    .single();

  if (error) throw new Error(`updatePartnerOpportunityStatus failed: ${error.message}`);
  return data as PartnerOpportunity;
}

// --- DELETE ---
export async function deletePartnerOpportunity(id: string): Promise<void> {
  const { error } = await supabase
    .from('partner_opportunities')
    .delete()
    .eq('id', id);

  if (error) throw new Error(`deletePartnerOpportunity failed: ${error.message}`);
}
