import { supabase } from "@/integrations/supabase/client";
import { Database } from "@/integrations/supabase/types";

export type Partner = Database["public"]["Tables"]["partners"]["Row"] & { 
    applications_open?: boolean;
    external_redirect_config?: any;
};
export type PartnerInsert = Database["public"]["Tables"]["partners"]["Insert"] & { 
    applications_open?: boolean;
    external_redirect_config?: any;
};
export type PartnerUpdate = Database["public"]["Tables"]["partners"]["Update"] & { 
    applications_open?: boolean;
    external_redirect_config?: any;
};

export interface PartnerStats {
    totalPartners: number;
    totalClicks: number;
    bestPartner: string;
    uniqueUsers: number;
    clicksPerPartner: number;
    clicksPerUser: number;
}

export async function getPartners(
    sortBy: string = 'name',
    sortOrder: string = 'asc'
): Promise<Partner[]> {
    const { data, error } = await supabase.rpc("get_partners", {
        p_sort_by: sortBy,
        p_sort_order: sortOrder
    });

    if (error) {
        console.error("Error fetching partners:", error);
        throw error;
    }

    return data as Partner[];
}

export async function getPartnerById(id: string): Promise<Partner> {
    const { data, error } = await supabase
        .from("partners")
        .select("*")
        .eq("id", id)
        .single();

    if (error) {
        console.error(`Error fetching partner ${id}:`, error);
        throw error;
    }

    return data;
}

export async function createPartner(partner: PartnerInsert): Promise<Partner> {
    const { data, error } = await (supabase.rpc as any)("manage_partner", {
        p_name: partner.name,
        p_description: partner.description,
        p_location: partner.location,
        p_type: partner.type,
        p_income: partner.income,
        p_dates: partner.dates,
        p_link: partner.link,
        p_coverimage: partner.coverimage,
        p_applications_open: partner.applications_open,
        p_external_redirect_config: partner.external_redirect_config
    });

    if (error) {
        console.error("Error creating partner:", error);
        throw error;
    }

    return data as Partner;
}

export async function updatePartner(id: string, partner: PartnerUpdate): Promise<Partner> {
    const { data, error } = await (supabase.rpc as any)("manage_partner", {
        p_id: id,
        p_name: partner.name,
        p_description: partner.description,
        p_location: partner.location,
        p_type: partner.type,
        p_income: partner.income,
        p_dates: partner.dates,
        p_link: partner.link,
        p_coverimage: partner.coverimage,
        p_applications_open: partner.applications_open,
        p_external_redirect_config: partner.external_redirect_config
    });

    if (error) {
        console.error(`Error updating partner ${id}:`, error);
        throw error;
    }

    return data as Partner;
}

export async function uploadPartnerCover(file: File): Promise<string> {
    const fileExt = file.name.split(".").pop();
    const fileName = `${Math.random().toString(36).substring(2)}.${fileExt}`;
    const filePath = `${fileName}`;

    const { error: uploadError } = await supabase.storage
        .from("partners")
        .upload(filePath, file);

    if (uploadError) {
        console.error("Error uploading image:", uploadError);
        throw uploadError;
    }

    const { data } = supabase.storage.from("partners").getPublicUrl(filePath);
    return data.publicUrl;
}

export async function getPartnerStatistics(): Promise<PartnerStats> {
    // Fetch all partners
    const { data: partners, error: partnersError } = await supabase
        .from("partners")
        .select("id, name");

    if (partnersError) throw partnersError;

    // Fetch all clicks
    const { data: clicks, error: clicksError } = await supabase
        .from("partners_click")
        .select("partner_id, clicks, user_id");

    if (clicksError) throw clicksError;

    const totalPartners = partners?.length || 0;
    const totalClicks = clicks?.reduce((acc, curr) => acc + curr.clicks, 0) || 0;

    // Best partner
    const partnerClicksMap: Record<string, number> = {};
    clicks?.forEach(click => {
        partnerClicksMap[click.partner_id] = (partnerClicksMap[click.partner_id] || 0) + click.clicks;
    });

    let bestPartnerId = "";
    let maxClicks = -1;
    Object.entries(partnerClicksMap).forEach(([id, count]) => {
        if (count > maxClicks) {
            maxClicks = count;
            bestPartnerId = id;
        }
    });

    const bestPartnerName = partners?.find(p => p.id === bestPartnerId)?.name || "N/A";

    // Unique users
    const uniqueUsers = new Set(clicks?.map(c => c.user_id)).size;

    // Averages
    const clicksPerPartner = totalPartners > 0 ? totalClicks / totalPartners : 0;
    const clicksPerUser = uniqueUsers > 0 ? totalClicks / uniqueUsers : 0;

    return {
        totalPartners,
        totalClicks,
        bestPartner: bestPartnerName,
        uniqueUsers,
        clicksPerPartner,
        clicksPerUser
    };
}

export async function getPartnerClicks(partnerId: string): Promise<number> {
    const { data, error } = await supabase
        .from("partners_click")
        .select("clicks")
        .eq("partner_id", partnerId);

    if (error) throw error;

    return data.reduce((acc, curr) => acc + curr.clicks, 0);
}

export async function deletePartner(id: string): Promise<void> {
    const { error } = await (supabase.rpc as any)("manage_partner", {
        p_id: id,
        p_delete: true
    });

    if (error) {
        console.error(`Error deleting partner ${id}:`, error);
        throw error;
    }
}
