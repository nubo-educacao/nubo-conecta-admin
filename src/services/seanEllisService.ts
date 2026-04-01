
import { supabase } from "@/integrations/supabase/client";
import { StudentFilters } from "./studentsService";

export interface SeanEllisScore {
    id: string;
    submitted_at: string;
    full_name: string;
    whatsapp_raw: string;
    whatsapp_normalized: string;
    sisu_subscribed: string;
    sisu_courses: string;
    sisu_status: string;
    sisu_cloudinha_influence: string;
    prouni_subscribed: string;
    prouni_courses: string;
    prouni_cloudinha_influence: string;
    prouni_status: string;
    disappointment_level: string;
    feedback: string;
    user_id: string | null;
}

export interface SeanEllisStats {
    total_respondents: number;
    total_identified_users: number;
    disappointment_distribution: Record<string, number>;
}

export const importSeanEllisData = async (data: any[]): Promise<{ success: boolean; count: number }> => {
    // Map CSV columns to JSON expected by RPC
    // CSV headers: Carimbo de data/hora,Qual seu nome completo?,Qual seu Whatsapp?, ...
    // We need to map these to: submitted_at, full_name, whatsapp_raw, etc.

    const mappedData = data.map((row: any) => ({
        submitted_at: row["Carimbo de data/hora"],
        full_name: row["Qual seu nome completo?"],
        whatsapp_raw: row["Qual seu Whatsapp?"],
        sisu_subscribed: row["Você se inscreveu no SISU 2026?"],
        sisu_courses: row["Se sim, em quais cursos e universidades você se inscreveu no SISU?"],
        sisu_status: row["E agora, olhando para o SISU, como está sua situação neste momento? ☁️"],
        sisu_cloudinha_influence: row["A Cloudinha influenciou de alguma forma o curso em que você se inscreveu no SISU?"],
        prouni_subscribed: row["Você se inscreveu no Prouni 2026?"],
        prouni_courses: row["Em quais cursos e universidades você se inscreveu no Prouni?"],
        prouni_cloudinha_influence: row["A Cloudinha influenciou de alguma forma o curso em que você se inscreveu no Prouni?"],
        prouni_status: row["E agora, como está sua situação no Prouni nesse momento?"],
        disappointment_level: row["Se a Cloudinha deixasse de existir, como você se sentiria?"],
        feedback: row["Deixe seus comentários, feedbacks ou que achar relevante 💙☁️"]
    }));

    const { data: result, error } = await supabase.rpc('import_sean_ellis_data', { data: mappedData });

    if (error) throw error;
    return result as any;
};

export const getSeanEllisData = async (
    page: number = 0,
    pageSize: number = 20,
    filters?: StudentFilters,
    sortBy: string = 'submitted_at',
    sortOrder: string = 'desc'
): Promise<{ data: SeanEllisScore[]; count: number }> => {
    const paramFilters = {
        p_page: page,
        p_page_size: pageSize,
        p_filter_name: filters?.fullName || null,
        p_filter_city: filters?.city || null,
        p_filter_education: filters?.education || null,
        p_filter_is_nubo_student: filters?.isNuboStudent ?? null,
        p_filter_income_min: filters?.incomeMin || null,
        p_filter_income_max: filters?.incomeMax || null,
        p_filter_quota_types: (filters?.quotaTypes && filters.quotaTypes.length > 0) ? filters.quotaTypes : null,
        p_sort_by: sortBy,
        p_sort_order: sortOrder
    };

    const { data, error } = await supabase.rpc('get_sean_ellis_data', paramFilters);

    if (error) throw error;

    const result = data as any;
    return {
        data: (result?.data || []) as SeanEllisScore[],
        count: result?.count || 0
    };
};

export const getSeanEllisStats = async (filters?: StudentFilters): Promise<SeanEllisStats> => {
    const paramFilters = {
        p_filter_name: filters?.fullName || null,
        p_filter_city: filters?.city || null,
        p_filter_education: filters?.education || null,
        p_filter_is_nubo_student: filters?.isNuboStudent ?? null,
        p_filter_income_min: filters?.incomeMin || null,
        p_filter_income_max: filters?.incomeMax || null,
        p_filter_quota_types: (filters?.quotaTypes && filters.quotaTypes.length > 0) ? filters.quotaTypes : null
    };

    const { data, error } = await supabase.rpc('get_sean_ellis_stats', paramFilters);

    if (error) throw error;
    return data as any as SeanEllisStats;
};
