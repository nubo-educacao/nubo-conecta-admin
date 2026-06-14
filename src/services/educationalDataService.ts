import { supabase } from "@/integrations/supabase/client";

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
    const formattedData = data.map((item: any) => ({
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

    const formattedData = data.map((item: any) => ({
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

    const formattedData = data.map((item: any) => ({
        ...item,
        course_name: item.courses?.course_name || 'Desconhecido'
    }));

    return { data: formattedData, count };
}
