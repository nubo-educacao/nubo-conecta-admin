
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

type CsvRow = Record<string, unknown>;

function csvValue(row: CsvRow, ...headers: string[]) {
    for (const header of headers) {
        const value = row[header] ?? row[`\uFEFF${header}`];
        if (value !== undefined && value !== null) return String(value).trim();
    }
    return "";
}

export const mapSeanEllisCsvRows = (rows: unknown[]) => rows.map((rawRow) => {
    const row = rawRow && typeof rawRow === "object" ? rawRow as CsvRow : {};

    return {
    submitted_at: csvValue(row, "Carimbo de data/hora"),
    full_name: csvValue(row, "Qual seu nome completo?"),
    whatsapp_raw: csvValue(row, "Qual seu Whatsapp?", "Qual seu WhatsApp?"),
    sisu_subscribed: csvValue(row, "Você se inscreveu no SISU 2026?"),
    sisu_courses: csvValue(row, "Se sim, em quais cursos e universidades você se inscreveu no SISU?"),
    sisu_status: csvValue(row, "E agora, olhando para o SISU, como está sua situação neste momento? ☁️"),
    sisu_cloudinha_influence: csvValue(row, "A Cloudinha influenciou de alguma forma o curso em que você se inscreveu no SISU?"),
    prouni_subscribed: csvValue(row, "Você se inscreveu no Prouni 2026?", "Você se inscreveu no PROUNI 2026?"),
    prouni_courses: csvValue(row, "Em quais cursos e universidades você se inscreveu no Prouni?"),
    prouni_cloudinha_influence: csvValue(row, "A Cloudinha influenciou de alguma forma o curso em que você se inscreveu no Prouni?"),
    prouni_status: csvValue(row, "E agora, como está sua situação no Prouni nesse momento?"),
    disappointment_level: csvValue(row, "Se a Cloudinha deixasse de existir, como você se sentiria?"),
    feedback: csvValue(row, "Deixe seus comentários, feedbacks ou que achar relevante 💙☁️"),
    };
});

export const importSeanEllisData = async (data: unknown[]): Promise<{ success: boolean; count: number }> => {
    const mappedData = mapSeanEllisCsvRows(data);

    const { data: result, error } = await supabase.rpc('import_sean_ellis_data', { data: mappedData });

    if (error) throw error;
    return result as { success: boolean; count: number };
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

    const result = data as { data?: SeanEllisScore[]; count?: number } | null;
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
    return data as SeanEllisStats;
};
