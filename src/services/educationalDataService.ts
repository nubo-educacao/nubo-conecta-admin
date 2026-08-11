import { supabase } from "@/integrations/supabase/client";

export type EducationalSource = "all" | "partner" | "mec";
export type OpportunityType = "all" | "sisu" | "prouni";

export interface EducationalInstitution {
    id: string;
    name: string;
    external_code: string | null;
    is_partner: boolean;
    state: string | null;
    igc: string | null;
    campus_count: number;
    course_count: number;
    open_opportunities_count: number;
}

export interface EducationalCampus {
    id: string;
    name: string;
    external_code: string | null;
    city: string | null;
    state: string | null;
    course_count: number;
    opportunity_count: number;
}

export interface EducationalCourse {
    id: string;
    course_name: string;
    course_code: string | null;
    degree_type: string | null;
    campus_id: string;
    campus_name: string;
    institution_id: string;
    institution_name: string;
    city: string | null;
    state: string | null;
    opportunity_count: number;
}

export interface EducationalOpportunity {
    id: string;
    shift: string | null;
    scholarship_type: string | null;
    concurrency_type: string | null;
    concurrency_tags: unknown;
    scholarship_tags: unknown;
    cutoff_score: number | null;
    year: number;
    semester: string | null;
    opportunity_type: "sisu" | "prouni" | string;
}

export interface EducationalFilterOptions {
    institutions: Array<{ id: string; name: string }>;
    degrees: string[];
    years: number[];
    states: string[];
}

interface LegacyCampusRow {
    institutions?: { name?: string | null } | null;
    [key: string]: unknown;
}

interface LegacyCourseRow {
    campus?: { name?: string | null } | null;
    [key: string]: unknown;
}

interface LegacyOpportunityRow {
    courses?: { course_name?: string | null } | null;
    [key: string]: unknown;
}

interface PaginatedRpcResult<T> {
    data: T[];
    total: number;
}

function normalizeSearch(value?: string) {
    const normalized = value?.trim();
    return normalized ? normalized : null;
}

async function runEducationalRpc<T>(name: string, params: Record<string, unknown>) {
    const { data, error } = await supabase.rpc(name, params);

    if (error) throw error;
    return data as T;
}

export async function getEducationalInstitutions(params: {
    page: number;
    pageSize: number;
    search?: string;
    state?: string;
    source?: EducationalSource;
}): Promise<PaginatedRpcResult<EducationalInstitution>> {
    return runEducationalRpc("get_admin_educational_institutions", {
        p_page: params.page,
        p_page_size: params.pageSize,
        p_search: normalizeSearch(params.search),
        p_state: params.state && params.state !== "all" ? params.state : null,
        p_source: params.source ?? "all",
    });
}

export async function getInstitutionCampuses(params: {
    institutionId: string;
    page: number;
    pageSize: number;
    search?: string;
}): Promise<PaginatedRpcResult<EducationalCampus>> {
    return runEducationalRpc("get_admin_institution_campuses", {
        p_institution_id: params.institutionId,
        p_page: params.page,
        p_page_size: params.pageSize,
        p_search: normalizeSearch(params.search),
    });
}

export async function getEducationalFilterOptions(): Promise<EducationalFilterOptions> {
    return runEducationalRpc("get_admin_educational_filter_options", {});
}

export async function getCampusFilterOptions(institutionId: string) {
    return runEducationalRpc<Array<{ id: string; name: string; city: string | null; state: string | null }>>(
        "get_admin_educational_campus_options",
        { p_institution_id: institutionId },
    );
}

export async function getEducationalCourses(params: {
    page: number;
    pageSize: number;
    search?: string;
    institutionId?: string;
    campusId?: string;
    degree?: string;
    year?: number;
    opportunityType?: OpportunityType;
}): Promise<PaginatedRpcResult<EducationalCourse>> {
    return runEducationalRpc("get_admin_educational_courses", {
        p_page: params.page,
        p_page_size: params.pageSize,
        p_search: normalizeSearch(params.search),
        p_institution_id: params.institutionId || null,
        p_campus_id: params.campusId || null,
        p_degree: params.degree && params.degree !== "all" ? params.degree : null,
        p_year: params.year || null,
        p_opportunity_type:
            params.opportunityType && params.opportunityType !== "all"
                ? params.opportunityType
                : null,
    });
}

export async function getCourseOpportunities(params: {
    courseId: string;
    year?: number;
    opportunityType?: OpportunityType;
}): Promise<EducationalOpportunity[]> {
    return runEducationalRpc("get_admin_course_opportunities", {
        p_course_id: params.courseId,
        p_year: params.year || null,
        p_opportunity_type:
            params.opportunityType && params.opportunityType !== "all"
                ? params.opportunityType
                : null,
    });
}

export async function getInstitutions(page: number, pageSize: number, search: string = "") {
    let query = supabase
        .from("institutions")
        .select("*", { count: "exact" });

    if (search) {
        query = query.ilike("name", `%${search}%`);
    }

    console.time('getInstitutions'); const { data, error, count } = await query
        .order("name", { ascending: true })
        .range(page * pageSize, (page + 1) * pageSize - 1);

    console.timeEnd('getInstitutions'); if (error) {
        console.error("Error fetching institutions:", error);
        throw error;
    }

    return { data, count };
}

export async function getCampus(page: number, pageSize: number, search: string = "") {
    let query = supabase
        .from("campus")
        .select("*, institutions!inner(name)", { count: "exact" });

    if (search) {
        query = query.or(`name.ilike.%${search}%,city.ilike.%${search}%`);
    }

    console.time('getInstitutions'); const { data, error, count } = await query
        .order("name", { ascending: true })
        .range(page * pageSize, (page + 1) * pageSize - 1);

    console.timeEnd('getInstitutions'); if (error) {
        console.error("Error fetching campus:", error);
        throw error;
    }

    // Format to include institution_name easily
    const formattedData = (data as unknown as LegacyCampusRow[]).map((item) => ({
        ...item,
        institution_name: item.institutions?.name || 'Desconhecida'
    }));

    return { data: formattedData, count };
}

export async function getCourses(page: number, pageSize: number, search: string = "") {
    let query = supabase
        .from("courses")
        .select("*, campus!inner(name)", { count: "exact" });

    if (search) {
        query = query.ilike("course_name", `%${search}%`);
    }

    console.time('getInstitutions'); const { data, error, count } = await query
        .order("course_name", { ascending: true })
        .range(page * pageSize, (page + 1) * pageSize - 1);

    console.timeEnd('getInstitutions'); if (error) {
        console.error("Error fetching courses:", error);
        throw error;
    }

    const formattedData = (data as unknown as LegacyCourseRow[]).map((item) => ({
        ...item,
        campus_name: item.campus?.name || 'Desconhecido'
    }));

    return { data: formattedData, count };
}

export async function getOpportunities(page: number, pageSize: number, search: string = "") {
    let query = supabase
        .from("opportunities")
        .select("*, courses!inner(course_name)", { count: "exact" });

    if (search) {
        // Search by course name using the joined table
        query = query.ilike("courses.course_name", `%${search}%`);
    }

    console.time('getInstitutions'); const { data, error, count } = await query
        .order("created_at", { ascending: false })
        .range(page * pageSize, (page + 1) * pageSize - 1);

    console.timeEnd('getInstitutions'); if (error) {
        console.error("Error fetching opportunities:", error);
        throw error;
    }

    const formattedData = (data as unknown as LegacyOpportunityRow[]).map((item) => ({
        ...item,
        course_name: item.courses?.course_name || 'Desconhecido'
    }));

    return { data: formattedData, count };
}
