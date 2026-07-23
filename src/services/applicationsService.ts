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

    return data as OpportunityPhase;
}

/**
 * Updates the phase of a single application.
 */
export async function updateApplicationPhase(
    applicationId: string,
    phaseId: string | null
): Promise<void> {
    const { data, error } = await supabase
        .from("student_applications")
        .update({ phase_id: phaseId })
        .eq("id", applicationId)
        .select("id");

    if (error) {
        console.error("Error updating application phase:", error);
        throw error;
    }

    if (!data || data.length === 0) {
        console.error("No rows updated. RLS might have prevented the update.");
        throw new Error("Não foi possível atualizar a fase (Permissão negada ou registro não encontrado).");
    }
}

/**
 * Updates the phase of multiple applications in bulk.
 */
export async function updateApplicationsPhaseBulk(
    applicationIds: string[],
    phaseId: string | null
): Promise<void> {
    const { error } = await supabase
        .from("student_applications")
        .update({ phase_id: phaseId })
        .in("id", applicationIds);

    if (error) {
        console.error("Error bulk updating application phases:", error);
        throw error;
    }
}

/**
 * Gets all opportunity phases for a given institution.
 */
export async function getPhasesByInstitution(
    institutionId: string
): Promise<OpportunityPhase[]> {
    const { data: opps, error: oppsError } = await supabase
        .from("partner_opportunities")
        .select("id")
        .eq("institution_id", institutionId);

    if (oppsError) {
        console.error("Error fetching partner opportunities:", oppsError);
        throw oppsError;
    }

    const oppIds = (opps || []).map(o => o.id);
    if (oppIds.length === 0) return [];

    const { data, error } = await supabase
        .from("opportunity_phases")
        .select("id, opportunity_id, name, description, sort_order, created_at")
        .in("opportunity_id", oppIds)
        .order("sort_order", { ascending: true });

    if (error) {
        console.error("Error fetching phases by institution:", error);
        throw error;
    }

    return (data ?? []) as OpportunityPhase[];
}

/**
 * Deletes a phase. If fallbackPhaseId is provided, moves all applications to it first.
 */
export async function deleteOpportunityPhase(
    phaseId: string,
    fallbackPhaseId?: string | null
): Promise<void> {
    if (fallbackPhaseId !== undefined) {
        // Move applications to the fallback phase
        const { error: moveError } = await supabase
            .from("student_applications")
            .update({ phase_id: fallbackPhaseId })
            .eq("phase_id", phaseId);

        if (moveError) {
            console.error("Error moving applications to fallback phase:", moveError);
            throw moveError;
        }
    }

    // Now delete the phase
    const { error: deleteError } = await supabase
        .from("opportunity_phases")
        .delete()
        .eq("id", phaseId);

    if (deleteError) {
        console.error("Error deleting opportunity phase:", deleteError);
        throw deleteError;
    }
}

/**
 * Reorders opportunity phases based on a provided array of phase IDs.
 * The order in the array dictates the new `sort_order`.
 */
export async function reorderOpportunityPhases(
    orderedPhaseIds: string[]
): Promise<void> {
    // Supabase JS doesn't have a built-in bulk update for different values per row.
    // We'll execute an update for each phase sequentially.
    for (let i = 0; i < orderedPhaseIds.length; i++) {
        const { error } = await supabase
            .from("opportunity_phases")
            .update({ sort_order: i })
            .eq("id", orderedPhaseIds[i]);

        if (error) {
            console.error(`Error updating sort_order for phase ${orderedPhaseIds[i]}:`, error);
            throw error;
        }
    }
}
