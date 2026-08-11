import { supabase } from "@/integrations/supabase/client";

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

export interface StudentFilters {
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
    filters?: {
        name?: string;
        city?: string;
        education?: string;
        isNuboStudent?: boolean | null;
        incomeRange?: [number | null, number | null];
        quotaTypes?: string[];
        state?: string;
        ageRange?: [number | null, number | null];
    };
    sortBy?: string;
    sortOrder?: string;
}

export const getStudents = async ({
    page = 0,
    pageSize = 20,
    filters,
    sortBy = "created_at",
    sortOrder = "desc",
}: GetStudentsOptions) => {
    try {
        const rpcParams = {
            p_page: page,
            p_page_size: pageSize,
            p_filter_name: filters?.name || null,
            p_filter_city: filters?.city || null,
            p_filter_education: filters?.education || null,
            p_filter_is_nubo_student: filters?.isNuboStudent ?? null,
            p_filter_income_min: filters?.incomeRange?.[0] || null,
            p_filter_income_max: filters?.incomeRange?.[1] || null,
            p_filter_quota_types: (filters?.quotaTypes && filters.quotaTypes.length > 0) ? filters.quotaTypes : null,
            p_sort_by: sortBy,
            p_sort_order: sortOrder,
            p_filter_state: filters?.state || null,
            p_filter_age_min: filters?.ageRange?.[0] || null,
            p_filter_age_max: filters?.ageRange?.[1] || null,
        }

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
}

export interface StudentDetails {
    profile: StudentProfile | null;
    preferences: UserPreference | null;
    enem_scores: UserEnemScore[];
    favorites: UserFavorite[];
    matches: UserMatch[];
    total_matches: number;
}

export const getStudentDetails = async (userId: string): Promise<StudentDetails> => {
    const { data: profile, error: profileError } = await supabase
        .from("user_profiles")
        .select("*")
        .eq("id", userId)
        .single();

    if (profileError) throw profileError;

    const { data: preferences, error: prefError } = await supabase
        .from("user_preferences")
        .select("*")
        .eq("user_id", userId)
        .maybeSingle();

    if (prefError) throw prefError;

    const { data: enem_scores, error: enemError } = await supabase
        .from("user_enem_scores")
        .select("*")
        .eq("user_id", userId)
        .order("year", { ascending: false });

    if (enemError) throw enemError;

    const { data: favorites, error: favError } = await supabase
        .from("user_favorites")
        .select(`
            *,
            courses ( course_name ),
            partner_opportunities ( name ),
            institutions ( name )
        `)
        .eq("user_id", userId);

    if (favError) throw favError;

    // Fetch Matches & Total Count using RPC to bypass RLS for admin
    const { data: matchesResponse, error: matchesError } = await supabase
        .rpc("get_student_matches_admin", { p_profile_id: userId });

    if (matchesError) throw matchesError;

    const totalMatchesCount = matchesResponse?.count || 0;
    const matches: UserMatch[] = matchesResponse?.matches?.map((m: any) => ({
        unified_opportunity_id: m.unified_opportunity_id,
        match_score: Number(m.match_score) || 0,
        title: m.title || "Oportunidade",
        provider_name: m.provider_name || "-"
    })) || [];

    const matchesListStr = matches
        .map(m => `${m.title} (${m.provider_name}) - ${Math.round(m.match_score)}%`)
        .join("; ");

    return {
        profile: {
            ...profile,
            whatsapp: profile.phone || profile.whatsapp || null,
            total_matches: totalMatchesCount || 0,
            matches_list: matchesListStr
        } as any as StudentProfile,
        preferences,
        enem_scores: enem_scores || [],
        favorites: favorites?.map((f: any) => ({
            ...f,
            courses: f.courses ? { name: f.courses.course_name } : null,
            partners: f.partner_opportunities ? { name: f.partner_opportunities.name } : f.institutions ? { name: f.institutions.name } : null
        })) || [],
        matches,
        total_matches: totalMatchesCount || 0
    };
};

export interface StudentStats {
    total_students: number;
    total_cities: number;
    total_states: number;
    average_age: number;
}

export const getStudentStats = async (filters?: StudentFilters): Promise<StudentStats> => {
    const { data, error } = await supabase
        .rpc('get_student_stats' as any, {
            filter_full_name: filters?.fullName || null,
            filter_city: filters?.city || null,
            filter_education: filters?.education || null,
            filter_is_nubo_student: filters?.isNuboStudent ?? null,
            filter_income_min: filters?.incomeMin || null,
            filter_income_max: filters?.incomeMax || null,
            filter_quota_types: (filters?.quotaTypes && filters.quotaTypes.length > 0) ? filters.quotaTypes : null,
            filter_state: filters?.state || null,
            filter_age_min: filters?.ageMin || null,
            filter_age_max: filters?.ageMax || null
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
