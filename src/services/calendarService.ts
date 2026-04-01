import { supabase } from "@/integrations/supabase/client";

export interface ImportantDate {
    id: string;
    title: string;
    description: string | null;
    start_date: string;
    end_date: string | null;
    type: string;
    created_at: string | null;
}

export type DateType = "prouni" | "sisu" | "partners" | "general";

export const DATE_TYPE_COLORS: Record<DateType, string> = {
    prouni: "#9747FF",
    sisu: "#024F86",
    partners: "#FF9900",
    general: "#38B1E4",
};

export const DATE_TYPE_LABELS: Record<DateType, string> = {
    prouni: "ProUni",
    sisu: "Sisu",
    partners: "Parceiros",
    general: "Geral",
};

export async function getImportantDates(): Promise<ImportantDate[]> {
    const { data, error } = await supabase
        .from("important_dates")
        .select("*")
        .order("start_date", { ascending: true });

    if (error) {
        console.error("Error fetching important dates:", error);
        throw error;
    }

    return data as ImportantDate[];
}

export async function createImportantDate(date: {
    title: string;
    description?: string;
    start_date: string;
    end_date?: string;
    type: string;
}): Promise<ImportantDate> {
    const { data, error } = await (supabase.rpc as any)("manage_important_date", {
        p_title: date.title,
        p_description: date.description || null,
        p_start_date: date.start_date,
        p_end_date: date.end_date || null,
        p_type: date.type,
    });

    if (error) {
        console.error("Error creating important date:", error);
        throw error;
    }

    return data as ImportantDate;
}

export async function updateImportantDate(
    id: string,
    date: {
        title?: string;
        description?: string;
        start_date?: string;
        end_date?: string;
        type?: string;
    }
): Promise<ImportantDate> {
    const { data, error } = await (supabase.rpc as any)("manage_important_date", {
        p_id: id,
        p_title: date.title,
        p_description: date.description,
        p_start_date: date.start_date,
        p_end_date: date.end_date,
        p_type: date.type,
    });

    if (error) {
        console.error(`Error updating important date ${id}:`, error);
        throw error;
    }

    return data as ImportantDate;
}

export async function deleteImportantDate(id: string): Promise<ImportantDate> {
    const { data, error } = await (supabase.rpc as any)("manage_important_date", {
        p_id: id,
        p_delete: true,
    });

    if (error) {
        console.error(`Error deleting important date ${id}:`, error);
        throw error;
    }

    return data as ImportantDate;
}

export async function bulkImportDates(
    dates: Array<{
        title: string;
        description?: string;
        start_date: string;
        end_date?: string;
        type: string;
    }>
): Promise<number> {
    const { data, error } = await (supabase.rpc as any)("bulk_import_important_dates", {
        p_dates: JSON.stringify(dates),
    });

    if (error) {
        console.error("Error bulk importing dates:", error);
        throw error;
    }

    return data as number;
}
