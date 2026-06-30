import { supabase } from "@/integrations/supabase/client";

// ─── Types ───────────────────────────────────────────────────────────────────

export interface StudentApplication {
    id: string;
    user_id: string;
    partner_id: string;
    status: "DRAFT" | "SUBMITTED";
    answers: Record<string, unknown>;
    created_at: string;
    updated_at: string;
}

export interface PartnerFormField {
    id: string;
    partner_id: string;
    step_id: string | null;
    field_name: string;
    question_text: string;
    data_type: string;
    options: unknown[] | null;
    mapping_source: string | null;
    is_criterion: boolean;
    criterion_rule: Record<string, unknown> | null;
    sort_order: number;
}

// ─── Service ─────────────────────────────────────────────────────────────────

/**
 * Gets the partner_id for the currently logged-in partner user.
 */
export async function getMyPartnerId(): Promise<string | null> {
    const { data, error } = await supabase.rpc("get_my_partner_id" as any);
    if (error) {
        console.error("Error fetching partner ID:", error);
        return null;
    }
    return data as string | null;
}

/**
 * Gets partner details by ID (from institutions + partner_institutions).
 */
export async function getPartnerDetails(partnerId: string) {
    const { data, error } = await supabase
        .from("institutions")
        .select(`
            id,
            name,
            created_at,
            updated_at,
            partner_institutions (
                description,
                location,
                logo_url,
                cover_url,
                brand_color,
                website_url
            )
        `)
        .eq("id", partnerId)
        .eq("is_partner", true)
        .single();

    if (error) {
        console.error("Error fetching partner details:", error);
        throw error;
    }

    return data;
}

export interface PartnerOpportunity {
    id: string;
    institution_id: string;
    name: string;
    status: string;
}

/**
 * Gets all partner opportunities for a given institution.
 */
export async function getPartnerOpportunities(institutionId: string): Promise<PartnerOpportunity[]> {
    const { data, error } = await supabase
        .from("partner_opportunities")
        .select("id, institution_id, name, status")
        .eq("institution_id", institutionId)
        .order("name", { ascending: true });

    if (error) {
        console.error("Error fetching partner opportunities:", error);
        throw error;
    }

    return (data ?? []) as PartnerOpportunity[];
}

/**
 * Gets the form field definitions for a partner.
 */
export async function getPartnerFormFields(partnerId: string): Promise<PartnerFormField[]> {
    // 1. Fetch steps for ordering
    const { data: steps } = await supabase
        .from("partner_steps" as any)
        .select("id, sort_order")
        .eq("partner_id", partnerId);

    // 2. Fetch forms
    const { data: forms, error } = await supabase
        .from("partner_forms" as any)
        .select("*")
        .eq("partner_id", partnerId);

    if (error) {
        console.error("Error fetching partner forms:", error);
        throw error;
    }

    const formsList = (forms ?? []) as unknown as PartnerFormField[];

    // 3. Sort intelligently: step_order ASC, then form_order ASC
    formsList.sort((a: any, b: any) => {
        const stepA = steps?.find((s: any) => s.id === a.step_id);
        const stepB = steps?.find((s: any) => s.id === b.step_id);
        
        const orderA = stepA?.sort_order ?? 9999;
        const orderB = stepB?.sort_order ?? 9999;

        if (orderA !== orderB) {
            return orderA - orderB;
        }
        return a.sort_order - b.sort_order;
    });

    return formsList;
}

/**
 * Gets all student applications for a specific partner.
 * RLS ensures only the partner's own applications are returned.
 */
export async function getApplicationsByPartner(partnerId: string): Promise<StudentApplication[]> {
    const { data, error } = await (supabase
        .from("student_applications" as any)
        .select("*")
        .eq("partner_id", partnerId)
        .order("created_at", { ascending: false }) as any);

    if (error) {
        console.error("Error fetching applications:", error);
        throw error;
    }

    return (data ?? []) as StudentApplication[];
}

/**
 * Gets user profile data to enrich the applications table.
 */
export async function getUserProfiles(userIds: string[]) {
    if (userIds.length === 0) return [];

    const { data, error } = await supabase
        .from("user_profiles" as any)
        .select("id, full_name, city, state, education")
        .in("id", userIds);

    if (error) {
        console.error("Error fetching user profiles:", error);
        return [];
    }

    return data ?? [];
}

export interface PartnerRedirectUser {
    full_name: string;
    whatsapp: string;
    redirect_url: string;
    created_at: string;
}

/**
 * Gets the users who clicked external redirects for a specific partner.
 */
export async function getPartnerRedirectUsers(partnerId: string): Promise<PartnerRedirectUser[]> {
    const { data, error } = await supabase.rpc("get_partner_redirect_users" as any, {
        p_partner_id: partnerId
    });

    if (error) {
        console.error("Error fetching partner redirect users:", error);
        return [];
    }

    return (data ?? []) as PartnerRedirectUser[];
}

// ─── Partner Steps & Full Form Fields (for Partner Portal Forms page) ────

export interface PartnerStep {
    id: string;
    partner_id: string;
    step_name: string;
    sort_order: number;
    introduction: string | null;
    secret_step: boolean;
    is_iterable: boolean | null;
    repeat_limit: number | null;
    conditional_rule: Record<string, unknown> | null;
}

export interface PartnerFormFieldFull extends PartnerFormField {
    optional: boolean;
    conditional_rule: Record<string, unknown> | null;
    maskking: string | null;
}

/**
 * Gets the steps for a partner, ordered by sort_order.
 */
export async function getPartnerSteps(partnerId: string): Promise<PartnerStep[]> {
    const { data, error } = await supabase
        .from("partner_steps" as any)
        .select("*")
        .eq("partner_id", partnerId)
        .order("sort_order", { ascending: true });

    if (error) {
        console.error("Error fetching partner steps:", error);
        throw error;
    }

    return (data ?? []) as unknown as PartnerStep[];
}

/**
 * Gets all form fields for a partner with full details, sorted by step then field order.
 */
export async function getPartnerFormFieldsFull(partnerId: string): Promise<PartnerFormFieldFull[]> {
    const { data: steps } = await supabase
        .from("partner_steps" as any)
        .select("id, sort_order")
        .eq("partner_id", partnerId);

    const { data: forms, error } = await supabase
        .from("partner_forms" as any)
        .select("*")
        .eq("partner_id", partnerId);

    if (error) {
        console.error("Error fetching partner forms:", error);
        throw error;
    }

    const formsList = (forms ?? []) as unknown as PartnerFormFieldFull[];

    formsList.sort((a: any, b: any) => {
        const stepA = steps?.find((s: any) => s.id === a.step_id);
        const stepB = steps?.find((s: any) => s.id === b.step_id);
        const orderA = stepA?.sort_order ?? 9999;
        const orderB = stepB?.sort_order ?? 9999;
        if (orderA !== orderB) return orderA - orderB;
        return a.sort_order - b.sort_order;
    });

    return formsList;
}
