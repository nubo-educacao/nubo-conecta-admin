import { supabase } from "@/integrations/supabase/client";

export interface PartnerSolicitation {
    id: string;
    institution_name: string;
    contact_name: string;
    whatsapp?: string;
    email?: string;
    how_did_you_know: string;
    goals?: string;
    created_at?: string;
}

export async function getPartnerSolicitations(): Promise<PartnerSolicitation[]> {
    const { data, error } = await supabase
        .from("partner_solicitations")
        .select("*")
        .order("created_at", { ascending: false });

    if (error) {
        console.error("Error fetching partner solicitations:", error);
        throw error;
    }

    return data as PartnerSolicitation[];
}
