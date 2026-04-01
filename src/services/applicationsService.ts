import { supabase } from "@/integrations/supabase/client";

// ─── Types ───────────────────────────────────────────────────────────────────

export interface ApplicationWithDetails {
    id: string;
    user_id: string;
    partner_id: string;
    partner_name: string | null;
    full_name: string | null;
    phone: string | null;
    status: "DRAFT" | "SUBMITTED";
    answers: Record<string, unknown>;
    eligibility_results: any;
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
 * Fetches the list of partners for the filter dropdown.
 */
export async function getPartnersList(): Promise<PartnerOption[]> {
    const { data, error } = await supabase
        .from("partners")
        .select("id, name")
        .order("name", { ascending: true });

    if (error) {
        console.error("Error fetching partners list:", error);
        throw error;
    }

    return (data ?? []) as PartnerOption[];
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
 * Gets the count of fields per partner to calculate application completion percentage.
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
