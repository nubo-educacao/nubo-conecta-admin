// partnersService.ts — Sprint 3.8
// CRUD for partner institutions using V1 normalized schema.
// Reads/writes to: institutions (is_partner=true) + partner_institutions.
// Replaces legacy V0 service that used the monolithic 'partners' table.

import { supabase } from "@/integrations/supabase/client";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface Partner {
    id: string;                       // institutions.id
    name: string;                     // institutions.name
    description: string | null;       // partner_institutions.description
    location: string | null;          // partner_institutions.location
    logo_url: string | null;          // partner_institutions.logo_url
    cover_url: string | null;         // partner_institutions.cover_url
    brand_color: string | null;       // partner_institutions.brand_color
    applications_open: boolean;       // partner_institutions.applications_open
    created_at: string;               // institutions.created_at
    updated_at: string;               // institutions.updated_at
}

export interface PartnerInput {
    name: string;
    description?: string;
    location?: string;
    logo_url?: string;
    cover_url?: string;
    brand_color?: string;
}

export interface PartnerStats {
    totalPartners: number;
    totalOpportunities: number;
}

// ---------------------------------------------------------------------------
// LIST
// ---------------------------------------------------------------------------

export async function getPartners(
    sortBy: string = "name",
    sortOrder: string = "asc"
): Promise<Partner[]> {
    const ascending = sortOrder === "asc";

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
                applications_open
            )
        `)
        .eq("is_partner", true)
        .order(sortBy === "name" ? "name" : "created_at", { ascending });

    if (error) {
        console.error("Error fetching partners:", error);
        throw error;
    }

    return (data ?? []).map((row: any) => ({
        id:          row.id,
        name:        row.name,
        description: row.partner_institutions?.description ?? null,
        location:    row.partner_institutions?.location ?? null,
        logo_url:    row.partner_institutions?.logo_url ?? null,
        cover_url:   row.partner_institutions?.cover_url ?? null,
        brand_color: row.partner_institutions?.brand_color ?? null,
        applications_open: row.partner_institutions?.applications_open ?? false,
        created_at:  row.created_at,
        updated_at:  row.updated_at,
    }));
}

// ---------------------------------------------------------------------------
// GET BY ID
// ---------------------------------------------------------------------------

export async function getPartnerById(id: string): Promise<Partner> {
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
                applications_open
            )
        `)
        .eq("id", id)
        .eq("is_partner", true)
        .single();

    if (error) {
        console.error(`Error fetching partner ${id}:`, error);
        throw error;
    }

    return {
        id:          data.id,
        name:        data.name,
        description: (data as any).partner_institutions?.description ?? null,
        location:    (data as any).partner_institutions?.location ?? null,
        logo_url:    (data as any).partner_institutions?.logo_url ?? null,
        cover_url:   (data as any).partner_institutions?.cover_url ?? null,
        brand_color: (data as any).partner_institutions?.brand_color ?? null,
        applications_open: (data as any).partner_institutions?.applications_open ?? false,
        created_at:  data.created_at,
        updated_at:  data.updated_at,
    };
}

// ---------------------------------------------------------------------------
// CREATE
// ---------------------------------------------------------------------------

export async function createPartner(input: PartnerInput): Promise<Partner> {
    // 1. Create institution
    const { data: inst, error: instError } = await supabase
        .from("institutions")
        .insert({ name: input.name, is_partner: true })
        .select("id, name, created_at, updated_at")
        .single();

    if (instError) {
        console.error("Error creating institution:", instError);
        throw instError;
    }

    // 2. Create partner_institutions row
    const { error: piError } = await supabase
        .from("partner_institutions")
        .insert({
            institution_id: inst.id,
            description:    input.description ?? null,
            location:       input.location ?? null,
            logo_url:       input.logo_url ?? null,
            cover_url:      input.cover_url ?? null,
            brand_color:    input.brand_color ?? null,
        });

    if (piError) {
        console.error("Error creating partner_institutions:", piError);
        // Clean up the institution if PI creation fails
        await supabase.from("institutions").delete().eq("id", inst.id);
        throw piError;
    }

    return {
        id:          inst.id,
        name:        inst.name,
        description: input.description ?? null,
        location:    input.location ?? null,
        logo_url:    input.logo_url ?? null,
        cover_url:   input.cover_url ?? null,
        brand_color: input.brand_color ?? null,
        applications_open: false,
        created_at:  inst.created_at,
        updated_at:  inst.updated_at,
    };
}

// ---------------------------------------------------------------------------
// UPDATE
// ---------------------------------------------------------------------------

export async function updatePartner(id: string, input: Partial<PartnerInput>): Promise<Partner> {
    // 1. Update institution name if provided
    if (input.name !== undefined) {
        const { error } = await supabase
            .from("institutions")
            .update({ name: input.name })
            .eq("id", id);

        if (error) {
            console.error(`Error updating institution ${id}:`, error);
            throw error;
        }
    }

    // 2. Upsert partner_institutions metadata
    const piUpdate: Record<string, any> = {};
    if (input.description !== undefined) piUpdate.description = input.description;
    if (input.location !== undefined)    piUpdate.location    = input.location;
    if (input.logo_url !== undefined)    piUpdate.logo_url    = input.logo_url;
    if (input.cover_url !== undefined)   piUpdate.cover_url   = input.cover_url;
    if (input.brand_color !== undefined) piUpdate.brand_color = input.brand_color;

    if (Object.keys(piUpdate).length > 0) {
        const { error } = await supabase
            .from("partner_institutions")
            .upsert({
                institution_id: id,
                ...piUpdate,
            });

        if (error) {
            console.error(`Error updating partner_institutions ${id}:`, error);
            throw error;
        }
    }

    return getPartnerById(id);
}

// ---------------------------------------------------------------------------
// DELETE
// ---------------------------------------------------------------------------

export async function deletePartner(id: string): Promise<void> {
    // partner_institutions has ON DELETE CASCADE from institutions FK,
    // but we just flip is_partner to false and delete the PI row to keep the institution.
    const { error: piError } = await supabase
        .from("partner_institutions")
        .delete()
        .eq("institution_id", id);

    if (piError) {
        console.error(`Error deleting partner_institutions ${id}:`, piError);
        throw piError;
    }

    const { error: instError } = await supabase
        .from("institutions")
        .update({ is_partner: false })
        .eq("id", id);

    if (instError) {
        console.error(`Error updating institution ${id}:`, instError);
        throw instError;
    }
}

// ---------------------------------------------------------------------------
// UPLOAD — Cover & Logo
// ---------------------------------------------------------------------------

export async function uploadPartnerCover(file: File): Promise<string> {
    const fileExt = file.name.split(".").pop();
    const fileName = `covers/${Date.now()}_${Math.random().toString(36).substring(2)}.${fileExt}`;

    const { error: uploadError } = await supabase.storage
        .from("partners")
        .upload(fileName, file);

    if (uploadError) {
        console.error("Error uploading cover:", uploadError);
        throw uploadError;
    }

    const { data } = supabase.storage.from("partners").getPublicUrl(fileName);
    return data.publicUrl;
}

export async function uploadPartnerLogo(file: File): Promise<string> {
    const fileExt = file.name.split(".").pop();
    const fileName = `logos/${Date.now()}_${Math.random().toString(36).substring(2)}.${fileExt}`;

    const { error: uploadError } = await supabase.storage
        .from("partners")
        .upload(fileName, file);

    if (uploadError) {
        console.error("Error uploading logo:", uploadError);
        throw uploadError;
    }

    const { data } = supabase.storage.from("partners").getPublicUrl(fileName);
    return data.publicUrl;
}

// ---------------------------------------------------------------------------
// STATISTICS
// ---------------------------------------------------------------------------

export async function getPartnerStatistics(): Promise<PartnerStats> {
    const { count: partnerCount, error: pError } = await supabase
        .from("institutions")
        .select("id", { count: "exact", head: true })
        .eq("is_partner", true);

    if (pError) throw pError;

    const { count: oppCount, error: oError } = await supabase
        .from("partner_opportunities")
        .select("id", { count: "exact", head: true });

    if (oError) throw oError;

    return {
        totalPartners:      partnerCount ?? 0,
        totalOpportunities: oppCount ?? 0,
    };
}
