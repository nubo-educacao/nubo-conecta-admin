import { supabase } from "@/integrations/supabase/client";

// ─── Types ───────────────────────────────────────────────────────────────────

export interface ApplicationWithDetails {
    id: string;
    user_id: string;
    partner_id: string;
    partner_name: string | null;
    /** Real partner institution (institutions.id), distinct from the opportunity. See ADR-0014. */
    institution_id?: string | null;
    institution_name?: string | null;
    full_name: string | null;
    phone: string | null;
    status: "DRAFT" | "SUBMITTED" | "redirected";
    answers: Record<string, unknown>;
    eligibility_results: any;
    created_at: string;
    phase_id?: string | null;
}

export interface OpportunityPhase {
    id: string;
    opportunity_id: string;
    name: string;
    description: string | null;
    sort_order: number;
    created_at: string;
}

export interface PartnerOption {
    id: string;
    name: string;
}

// ─── Service ─────────────────────────────────────────────────────────────────

/**
 * Fetches student applications enriched with user profile, phone, and partner name.
 * Pass partnerId to filter by a specific partner, or omit for all applications.
 */
export async function getApplicationsWithDetails(
    partnerId?: string
): Promise<ApplicationWithDetails[]> {
    const params: Record<string, unknown> = {};
    if (partnerId) {
        params.p_partner_id = partnerId;
    }

    const { data, error } = await (supabase.rpc as any)(
        "get_student_applications_with_details",
        params
    );

    if (error) {
        console.error("Error fetching applications:", error);
        throw error;
    }

    return (data ?? []) as ApplicationWithDetails[];
}

/**
 * Fetches student applications for a partner institution.
 * Used by partner portal to show applications across all opportunities of the institution.
 */
export async function getApplicationsByInstitution(
    institutionId: string
): Promise<ApplicationWithDetails[]> {
    const { data, error } = await (supabase.rpc as any)(
        "get_partner_applications_by_institution",
        { p_institution_id: institutionId }
    );

    if (error) {
        console.error("Error fetching applications by institution:", error);
        throw error;
    }

    return (data ?? []) as ApplicationWithDetails[];
}

/**
 * Fetches the list of partners for the filter dropdown.
 */
export async function getPartnersList(): Promise<PartnerOption[]> {
    const { data, error } = await supabase
        .from("partner_opportunities")
        .select("id, name")
        .order("name", { ascending: true });

    if (error) {
        console.error("Error fetching partners list:", error);
        throw error;
    }

    return (data ?? []) as PartnerOption[];
}

/**
 * Fetches the list of partner institutions for the Parceiro filter dropdown (ADR-0014).
 * Distinct from getPartnersList(), which actually lists partner_opportunities.
 */
export async function getInstitutionsList(): Promise<PartnerOption[]> {
    const { data, error } = await supabase
        .from("institutions")
        .select("id, name")
        .eq("is_partner", true)
        .order("name", { ascending: true });

    if (error) {
        console.error("Error fetching institutions list:", error);
        throw error;
    }

    return (data ?? []) as PartnerOption[];
}

/**
 * Gets all opportunity phases across every opportunity (admin Fase filter, ADR-0014).
 * Unlike getPhasesByInstitution/getOpportunityPhases, this is not scoped to a
 * single institution or opportunity — used where the applications list itself
 * is not pre-filtered to one opportunity (e.g. the admin /applications table).
 */
export async function getAllPhases(): Promise<OpportunityPhase[]> {
    const { data, error } = await supabase
        .from("opportunity_phases")
        .select("id, opportunity_id, name, description, sort_order, created_at")
        .order("sort_order", { ascending: true });

    if (error) {
        console.error("Error fetching all phases:", error);
        throw error;
    }

    return (data ?? []) as OpportunityPhase[];
}

/**
 * Gets the count of eligible students for a specific partner.
 * Uses the calculate_passport_eligibility results stored in user_profiles.
 */
export async function getEligibleCountForPartner(partnerId: string): Promise<number> {
    const { data, error } = await (supabase.rpc as any)("get_eligible_count_for_partner", {
        p_partner_id: partnerId,
    });

    if (error) {
        console.error("Error fetching eligible count:", error);
        return 0;
    }

    return (data as number) || 0;
}

/**
 * Gets the count of eligible students for a partner institution.
 * Used by partner portal to count eligible students across all opportunities.
 */
export async function getEligibleCountByInstitution(institutionId: string): Promise<number> {
    const { data, error } = await (supabase.rpc as any)("get_eligible_count_by_institution", {
        p_institution_id: institutionId,
    });

    if (error) {
        console.error("Error fetching eligible count by institution:", error);
        return 0;
    }

    return (data as number) || 0;
}

/**
 * Gets the count of fields per partner to calculate application completion percentage.
 * @deprecated Use getPartnerFormFieldsMap for smart progress calculation.
 */
export async function getPartnerFormCounts(): Promise<Record<string, number>> {
    const { data, error } = await supabase.from('partner_forms').select('partner_id');
    if (error) {
        console.error("Error fetching partner forms count:", error);
        return {};
    }
    const counts: Record<string, number> = {};
    for (const row of (data || [])) {
        counts[row.partner_id] = (counts[row.partner_id] || 0) + 1;
    }
    return counts;
}

/**
 * Fetches all partner_forms fields grouped by partner_id.
 * Used to calculate smart completion percentages (optional + conditional_rule aware).
 */
export async function getPartnerFormFieldsMap(): Promise<Record<string, import("@/services/partnerPortalService").PartnerFormField[]>> {
    const { data, error } = await supabase.from('partner_forms').select('*');
    if (error) {
        console.error("Error fetching partner forms fields:", error);
        return {};
    }
    const map: Record<string, import("@/services/partnerPortalService").PartnerFormField[]> = {};
    for (const row of (data || [])) {
        if (!map[row.partner_id]) map[row.partner_id] = [];
        map[row.partner_id].push(row as import("@/services/partnerPortalService").PartnerFormField);
    }
    return map;
}

/**
 * Gets all phases for a given opportunity.
 */
export async function getOpportunityPhases(opportunityId: string): Promise<OpportunityPhase[]> {
    const { data, error } = await supabase
        .from("opportunity_phases")
        .select("id, opportunity_id, name, description, sort_order, created_at")
        .eq("opportunity_id", opportunityId)
        .order("sort_order", { ascending: true });

    if (error) {
        console.error("Error fetching opportunity phases:", error);
        throw error;
    }

    return (data ?? []) as OpportunityPhase[];
}

/**
 * Creates a new phase for an opportunity.
 */
export async function createOpportunityPhase(
    opportunityId: string,
    name: string,
    sortOrder: number = 0
): Promise<OpportunityPhase> {
    const { data, error } = await supabase
        .from("opportunity_phases")
        .insert({ opportunity_id: opportunityId, name, sort_order: sortOrder })
        .select()
        .single();

    if (error) {
        console.error("Error creating opportunity phase:", error);
        throw error;
    }

    return data as unknown as OpportunityPhase;
}

/**
 * Updates an opportunity phase.
 */
export async function updateOpportunityPhase(
    phaseId: string,
    updates: Partial<Pick<OpportunityPhase, 'name' | 'sort_order'>>
): Promise<void> {
    const { error } = await supabase
        .from("opportunity_phases")
        .update(updates)
        .eq("id", phaseId);

    if (error) {
        console.error("Error updating opportunity phase:", error);
        throw error;
    }
}

/**
 * Deletes an opportunity phase.
 */
export async function deleteOpportunityPhase(phaseId: string): Promise<void> {
    const { error } = await supabase
        .from("opportunity_phases")
        .delete()
        .eq("id", phaseId);

    if (error) {
        console.error("Error deleting opportunity phase:", error);
        throw error;
    }
}

/**
 * Updates the phase_id for a student application.
 */
export async function updateApplicationPhase(appId: string, phaseId: string | null): Promise<void> {
    const { error } = await supabase
        .from("student_applications" as any)
        .update({ phase_id: phaseId })
        .eq("id", appId);

    if (error) {
        console.error("Error updating application phase:", error);
        throw error;
    }
}

/**
 * Updates the phase_id for multiple student applications at once.
 */
export async function updateApplicationsPhaseBulk(appIds: string[], phaseId: string | null): Promise<void> {
    const { error } = await supabase
        .from("student_applications" as any)
        .update({ phase_id: phaseId })
        .in("id", appIds);

    if (error) {
        console.error("Error updating applications phases in bulk:", error);
        throw error;
    }
}
