import { supabase } from "@/integrations/supabase/client";
import { attributionRpcArgs, type AttributionFilter } from "@/lib/attributionFilter";

export interface StudentProfile {
    id: string;
    full_name: string | null;
    age: number | null;
    city: string | null;
    education: string | null;
    state: string | null;
    is_nubo_student: boolean;
    created_at: string;
    whatsapp?: string | null;
    race?: string | null;
    per_capita_income?: number | string | null;
    quota_types?: string[] | null;
    draft_applications_count?: number | string | null;
    draft_applications_list?: string | null;
    completed_applications_count?: number | string | null;
    completed_applications_list?: string | null;
    total_matches?: number | string | null;
    matches_list?: string | null;
    favorites_list?: string | null;
}

export interface UserPreference {
    id: string;
    user_id: string;
    course_interest: string[] | null;
    enem_score: number | null;
    preferred_shifts: string[] | null;
    university_preference: string | null;
    program_preference: string | null;
    family_income_per_capita: number | null;
    quota_types: string[] | null;
    location_preference: string | null;
    state_preference: string | null;
}

export interface UserEnemScore {
    id: string;
    user_id: string;
    year: number;
    nota_linguagens: number | null;
    nota_ciencias_humanas: number | null;
    nota_ciencias_natureza: number | null;
    nota_matematica: number | null;
    nota_redacao: number | null;
}

export interface UserFavorite {
    id: string;
    user_id: string;
    course_id: string | null;
    partner_id: string | null;
    created_at: string;
    courses?: { name: string } | null;
    partners?: { name: string } | null;
}

export interface StudentDetails {
    profile: StudentProfile | null;
    preferences: UserPreference | null;
    enem_scores: UserEnemScore[];
    favorites: UserFavorite[];
}

/**
 * Filtros da tela de Estudantes. É o MESMO objeto que alimenta lista, total,
 * cards de stats e exportação — ver toStudentFilterParams.
 * Campanha/divulgador: recorte first-touch (TP-7, artefato Snaps 46d78fd5).
 */
export interface StudentFilters extends AttributionFilter {
    fullName?: string;
    city?: string;
    education?: string;
    isNuboStudent?: boolean | null;
    incomeMin?: number;
    incomeMax?: number;
    quotaTypes?: string[];
    state?: string;
    ageMin?: number;
    ageMax?: number;
}

/**
 * Colunas que a RPC `get_students_paginated` sabe ordenar.
 *
 * Espelha o CASE da migration 20260811140000_fix_students_sort_and_harden_get_students_paginated.
 * Se a tabela oferecer uma coluna que não esteja aqui (e no CASE da RPC), a função
 * cai no ELSE e ordena por created_at **sem sinalizar erro** — foi exatamente o
 * bug do card 1a658f84, em que `age` e `whatsapp` eram clicáveis mas não ordenavam.
 * O teste `src/test/students-sort-contract.test.tsx` trava esse acoplamento.
 */
export const SORTABLE_STUDENT_FIELDS = [
    "full_name",
    "age",
    "city",
    "education",
    "whatsapp",
    "is_nubo_student",
    "created_at",
] as const;

export type SortableStudentField = (typeof SORTABLE_STUDENT_FIELDS)[number];

export interface GetStudentsOptions {
    page?: number;
    pageSize?: number;
    filters?: StudentFilters;
    sortBy?: string;
    sortOrder?: string;
}

/**
 * Filtros comuns de get_students_paginated e get_student_stats, já com os
 * nomes de parâmetro de cada RPC. Uma fonte só: antes a lista lia `name`,
 * `incomeRange` e `ageRange`, que a página nunca enviava — nome, renda e idade
 * filtravam os cards mas não a lista nem a exportação.
 */
function toStudentFilterValues(filters?: StudentFilters) {
    return {
        name: filters?.fullName || null,
        city: filters?.city || null,
        education: filters?.education || null,
        isNuboStudent: filters?.isNuboStudent ?? null,
        incomeMin: filters?.incomeMin || null,
        incomeMax: filters?.incomeMax || null,
        quotaTypes: filters?.quotaTypes && filters.quotaTypes.length > 0 ? filters.quotaTypes : null,
        state: filters?.state || null,
        ageMin: filters?.ageMin || null,
        ageMax: filters?.ageMax || null,
        attribution: attributionRpcArgs(filters ?? {}),
    };
}

export const getStudents = async ({
    page = 0,
    pageSize = 20,
    filters,
    sortBy = "created_at",
    sortOrder = "desc",
}: GetStudentsOptions) => {
    try {
        const f = toStudentFilterValues(filters);
        const rpcParams = {
            p_page: page,
            p_page_size: pageSize,
            p_filter_name: f.name,
            p_filter_city: f.city,
            p_filter_education: f.education,
            p_filter_is_nubo_student: f.isNuboStudent,
            p_filter_income_min: f.incomeMin,
            p_filter_income_max: f.incomeMax,
            p_filter_quota_types: f.quotaTypes,
            p_sort_by: sortBy,
            p_sort_order: sortOrder,
            p_filter_state: f.state,
            p_filter_age_min: f.ageMin,
            p_filter_age_max: f.ageMax,
            ...f.attribution,
        };

        const { data, error } = await supabase.rpc("get_students_paginated", rpcParams as any);

        if (error) {
            console.error("RPC Error:", error);
            throw error;
        }

        const response = data as { data: any[]; count: number };
        const students = response.data || [];

        const enrichedStudents = students.map((s: any) => ({
            ...s,
            per_capita_income: s.per_capita_income ?? 0,
            quota_types: s.quota_types ?? [],
            _computed: {
                draftApplicationsCount: s.draft_applications_count ?? 0,
                draftApplicationsList: s.draft_applications_list ?? "",
                completedApplicationsCount: s.completed_applications_count ?? 0,
                completedApplicationsList: s.completed_applications_list ?? "",
                totalMatches: s.total_matches ?? 0,
                matchesList: s.matches_list ?? "",
                favoritesList: s.favorites_list ?? ""
            }
        }));

        return {
        data: enrichedStudents,
        count: response.count || 0
    };
    } catch (error) {
        console.error("Error fetching students:", error);
        throw error;
    }
};

export interface UserMatch {
    unified_opportunity_id: string;
    match_score: number;
    title: string;
    provider_name: string;
    match_details?: unknown;
}

export interface StudentDetails {
    profile: StudentProfile | null;
    preferences: UserPreference | null;
    enem_scores: UserEnemScore[];
    favorites: UserFavorite[];
    matches: UserMatch[];
    total_matches: number;
    source_errors?: Partial<Record<StudentDetailSource, string>>;
}

export type StudentDetailSource = 'profile' | 'preferences' | 'enem_scores' | 'favorites' | 'matches';

export const getStudentDetails = async (userId: string, matchPage = 0, options: { includeMatches?: boolean } = {}): Promise<StudentDetails> => {
    const sources = ['profile', 'preferences', 'enem_scores', 'favorites', 'matches'] as const;
    const results = await Promise.allSettled([
        supabase.from("user_profiles").select("*").eq("id", userId).single(),
        supabase.from("user_preferences").select("*").eq("user_id", userId).maybeSingle(),
        supabase.from("user_enem_scores").select("*").eq("user_id", userId).order("year", { ascending: false }),
        supabase.from("user_favorites").select(`
            *, courses ( course_name ), partner_opportunities ( name ), institutions ( name )
        `).eq("user_id", userId),
        options.includeMatches === false ? Promise.resolve({ data: { matches: [], count: 0 }, error: null })
            : supabase.rpc("get_student_matches_admin_page" as any, { p_profile_id: userId, p_page: matchPage, p_page_size: 20 }),
    ]);
    const source_errors: Partial<Record<StudentDetailSource, string>> = {};
    const values: Record<string, any> = {};
    results.forEach((result, index) => {
        const source = sources[index];
        const error = result.status === 'rejected' ? result.reason : result.value.error;
        if (error) {
            source_errors[source] = 'Não foi possível carregar esta seção.';
            // No response payloads or profile data in diagnostics.
            console.error(`[StudentDetails] fonte indisponível: ${source}`);
        } else if (result.status === 'fulfilled') values[source] = result.value.data;
    });
    const profile = values.profile;
    const matches: UserMatch[] = (values.matches?.matches ?? []).map((m: any) => ({
        unified_opportunity_id: m.unified_opportunity_id,
        match_score: Number(m.match_score) || 0,
        match_details: m.match_details,
        title: m.title || "Oportunidade",
        provider_name: m.provider_name || "-",
    }));
    const total_matches = values.matches?.count ?? 0;
    return {
        profile: profile ? {
            ...profile, whatsapp: profile.phone || profile.whatsapp || null,
            total_matches, matches_list: matches.map(m => `${m.title} (${m.provider_name}) - ${Math.round(m.match_score)}%`).join("; "),
        } : null,
        preferences: values.preferences ?? null,
        enem_scores: values.enem_scores ?? [],
        favorites: (values.favorites ?? []).map((f: any) => ({
            ...f, courses: f.courses ? { name: f.courses.course_name } : null,
            partners: f.partner_opportunities ? { name: f.partner_opportunities.name } : f.institutions ? { name: f.institutions.name } : null,
        })),
        matches, total_matches, source_errors,
    };
};

export interface StudentStats {
    total_students: number;
    total_cities: number;
    total_states: number;
    average_age: number;
}

export const getStudentStats = async (filters?: StudentFilters): Promise<StudentStats> => {
    const f = toStudentFilterValues(filters);
    const { data, error } = await supabase
        .rpc('get_student_stats' as any, {
            filter_full_name: f.name,
            filter_city: f.city,
            filter_education: f.education,
            filter_is_nubo_student: f.isNuboStudent,
            filter_income_min: f.incomeMin,
            filter_income_max: f.incomeMax,
            filter_quota_types: f.quotaTypes,
            filter_state: f.state,
            filter_age_min: f.ageMin,
            filter_age_max: f.ageMax,
            ...f.attribution,
        });

    if (error) throw error;
    return data as any as StudentStats;
};

export const importNuboStudents = async (students: any[]): Promise<{ imported_whitelist_entries: number, updated_existing_profiles: number }> => {
    const { data, error } = await supabase
        .rpc('import_nubo_students' as any, { students });

    if (error) throw error;
    return data as any;
};
