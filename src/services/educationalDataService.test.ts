import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { supabase } from "@/integrations/supabase/client";
import {
  getCourseOpportunities,
  getEducationalCourses,
  getEducationalInstitutions,
  getInstitutionCampuses,
} from "./educationalDataService";

vi.mock("@/integrations/supabase/client", () => ({
  supabase: { rpc: vi.fn() },
}));

describe("educationalDataService agrupado", () => {
  beforeEach(() => {
    vi.mocked(supabase.rpc).mockResolvedValue({
      data: { data: [], total: 0 },
      error: null,
    } as never);
  });

  it("pagina e filtra instituições no servidor", async () => {
    await getEducationalInstitutions({
      page: 2,
      pageSize: 20,
      search: "federal",
      state: "RJ",
      source: "mec",
    });

    expect(supabase.rpc).toHaveBeenCalledWith(
      "get_admin_educational_institutions",
      {
        p_page: 2,
        p_page_size: 20,
        p_search: "federal",
        p_state: "RJ",
        p_source: "mec",
      },
    );
  });

  it("carrega campus somente após o drill da instituição", async () => {
    await getInstitutionCampuses({
      institutionId: "inst-1",
      page: 0,
      pageSize: 15,
      search: "centro",
    });

    expect(supabase.rpc).toHaveBeenCalledWith(
      "get_admin_institution_campuses",
      {
        p_institution_id: "inst-1",
        p_page: 0,
        p_page_size: 15,
        p_search: "centro",
      },
    );
  });

  it("envia todos os filtros do explorer de cursos ao servidor", async () => {
    await getEducationalCourses({
      page: 1,
      pageSize: 20,
      search: "engenharia",
      institutionId: "inst-1",
      campusId: "campus-1",
      degree: "Bacharelado",
      year: 2026,
      opportunityType: "sisu",
    });

    expect(supabase.rpc).toHaveBeenCalledWith(
      "get_admin_educational_courses",
      expect.objectContaining({
        p_page: 1,
        p_page_size: 20,
        p_search: "engenharia",
        p_institution_id: "inst-1",
        p_campus_id: "campus-1",
        p_degree: "Bacharelado",
        p_year: 2026,
        p_opportunity_type: "sisu",
      }),
    );
  });

  it("busca oportunidades somente quando o curso é expandido", async () => {
    await getCourseOpportunities({
      courseId: "course-1",
      year: 2026,
      opportunityType: "prouni",
    });

    expect(supabase.rpc).toHaveBeenCalledWith(
      "get_admin_course_opportunities",
      {
        p_course_id: "course-1",
        p_year: 2026,
        p_opportunity_type: "prouni",
      },
    );
  });

  it("mantém o contrato SQL sem a matview removida e reutiliza search_opportunities", () => {
    const migration = readFileSync(
      resolve("supabase/migrations/20260811170000_admin_educational_explorers.sql"),
      "utf8",
    );

    expect(migration).toContain("public.search_opportunities");
    expect(migration).not.toContain("mv_course_catalog");
    expect(migration).toContain("SECURITY DEFINER");
    expect(migration).toContain("public.is_backoffice_admin()");
    expect(migration).toContain("REVOKE EXECUTE");
  });
});
