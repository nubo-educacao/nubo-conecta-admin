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

export const getStudents = async (
    page: number = 0,
    pageSize: number = 20,
    filters?: StudentFilters,
    sortBy: string = 'created_at',
    sortOrder: string = 'desc'
): Promise<{ data: StudentProfile[], count: number }> => {
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
        p_sort_order: sortOrder,
        p_filter_state: filters?.state || null,
        p_filter_age_min: filters?.ageMin || null,
        p_filter_age_max: filters?.ageMax || null
    };

    const { data, error } = await supabase.rpc('get_students_paginated' as any, paramFilters);

    if (error) {
        throw error;
    }

    const result = data as any;
    let students = (result?.data || []) as StudentProfile[];
    const count = result?.count || 0;

    if (students.length > 0) {
        const studentIds = students.map(s => s.id);

        const [
            { data: incomes },
            { data: preferences },
            { data: applications },
            { data: matches },
            { data: favorites }
        ] = await Promise.all([
            supabase.from("user_income").select("user_id, per_capita_income").in("user_id", studentIds),
            supabase.from("user_preferences").select("user_id, family_income_per_capita, quota_types").in("user_id", studentIds),
            supabase.from("student_applications").select("user_id, status, partner_id, partner_opportunities(name)").in("user_id", studentIds),
            supabase.from("user_opportunity_matches").select("profile_id, match_score, unified_opportunity_id").in("profile_id", studentIds),
            supabase.from("user_favorites").select("user_id, course_id, partner_opportunities_id, institution_id, courses(course_name), partners(name)").in("user_id", studentIds)
        ]);

        const incomeMap = new Map((incomes || []).map((i: any) => [i.user_id, i.per_capita_income]));
        const prefMap = new Map((preferences || []).map((p: any) => [p.user_id, p]));

        // Group applications
        const draftCountMap = new Map<string, number>();
        const draftListMap = new Map<string, string[]>();
        const completedCountMap = new Map<string, number>();
        const completedListMap = new Map<string, string[]>();

        (applications || []).forEach((app: any) => {
            const partnerName = app.partner_opportunities?.name || "Parceiro";
            if (app.status === "DRAFT") {
                draftCountMap.set(app.user_id, (draftCountMap.get(app.user_id) || 0) + 1);
                const current = draftListMap.get(app.user_id) || [];
                current.push(partnerName);
                draftListMap.set(app.user_id, current);
            } else {
                completedCountMap.set(app.user_id, (completedCountMap.get(app.user_id) || 0) + 1);
                const current = completedListMap.get(app.user_id) || [];
                current.push(partnerName);
                completedListMap.set(app.user_id, current);
            }
        });

        // Group matches count
        const matchCountMap = new Map<string, number>();
        (matches || []).forEach((m: any) => {
            matchCountMap.set(m.profile_id, (matchCountMap.get(m.profile_id) || 0) + 1);
        });

        // Group favorites list
        const favListMap = new Map<string, string[]>();
        (favorites || []).forEach((f: any) => {
            const name = f.courses?.course_name || f.partners?.name || f.course_id || f.partner_opportunities_id;
            if (name) {
                const current = favListMap.get(f.user_id) || [];
                current.push(name);
                favListMap.set(f.user_id, current);
            }
        });

        students = students.map(s => {
            const pref = prefMap.get(s.id);
            return {
                ...s,
                per_capita_income: s.per_capita_income ?? incomeMap.get(s.id) ?? pref?.family_income_per_capita ?? null,
                quota_types: s.quota_types ?? pref?.quota_types ?? null,
                draft_applications_count: s.draft_applications_count ?? draftCountMap.get(s.id) ?? 0,
                draft_applications_list: s.draft_applications_list ?? (draftListMap.get(s.id)?.join(", ") || null),
                completed_applications_count: s.completed_applications_count ?? completedCountMap.get(s.id) ?? 0,
                completed_applications_list: s.completed_applications_list ?? (completedListMap.get(s.id)?.join(", ") || null),
                total_matches: s.total_matches ?? matchCountMap.get(s.id) ?? 0,
                favorites_list: s.favorites_list ?? (favListMap.get(s.id)?.join(", ") || null)
            };
        });
    }

    return {
        data: students,
        count
    };
};

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
            partners ( name )
        `)
        .eq("user_id", userId);

    if (favError) throw favError;

    return {
        profile: profile as any as StudentProfile,
        preferences,
        enem_scores: enem_scores || [],
        favorites: favorites?.map((f: any) => ({
            ...f,
            courses: f.courses ? { name: f.courses.course_name } : null,
            partners: f.partners ? { name: f.partners.name } : null
        })) || []
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
