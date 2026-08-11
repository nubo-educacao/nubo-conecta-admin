import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import {
  getCampusFilterOptions,
  getCourseOpportunities,
  getEducationalCourses,
  getEducationalFilterOptions,
  getEducationalInstitutions,
  getInstitutionCampuses,
} from "@/services/educationalDataService";
import InstitutionsCampus from "./InstitutionsCampus";
import OpportunitiesCourses from "./OpportunitiesCourses";

vi.mock("@/services/educationalDataService", () => ({
  getEducationalFilterOptions: vi.fn(),
  getEducationalInstitutions: vi.fn(),
  getInstitutionCampuses: vi.fn(),
  getCampusFilterOptions: vi.fn(),
  getEducationalCourses: vi.fn(),
  getCourseOpportunities: vi.fn(),
}));

function renderPage(page: React.ReactNode) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      {page}
    </QueryClientProvider>,
  );
}

describe("exploradores educacionais", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(getEducationalFilterOptions).mockResolvedValue({
      institutions: [],
      degrees: [],
      years: [2026],
      states: ["RJ"],
    });
    vi.mocked(getCampusFilterOptions).mockResolvedValue([]);
  });

  it("carrega campus somente depois do drill da instituição", async () => {
    vi.mocked(getEducationalInstitutions).mockResolvedValue({
      data: [{
        id: "inst-1",
        name: "Universidade Nubo",
        external_code: "123",
        is_partner: true,
        state: "RJ",
        igc: "5",
        campus_count: 1,
        course_count: 20,
        open_opportunities_count: 8,
      }],
      total: 1,
    });
    vi.mocked(getInstitutionCampuses).mockResolvedValue({
      data: [{
        id: "campus-1",
        name: "Campus Centro",
        external_code: "321",
        city: "Rio de Janeiro",
        state: "RJ",
        course_count: 20,
        opportunity_count: 40,
      }],
      total: 1,
    });

    renderPage(<InstitutionsCampus />);

    expect(await screen.findByText("Universidade Nubo")).toBeVisible();
    expect(getInstitutionCampuses).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: /Universidade Nubo/ }));

    expect(await screen.findByText("Campus Centro")).toBeVisible();
    expect(screen.getByText("5")).toBeVisible();
    expect(getInstitutionCampuses).toHaveBeenCalledWith(expect.objectContaining({ institutionId: "inst-1" }));
  });

  it("carrega oportunidades somente ao expandir o curso", async () => {
    vi.mocked(getEducationalCourses).mockResolvedValue({
      data: [{
        id: "course-1",
        course_name: "Direito",
        course_code: "D-1",
        degree_type: "Bacharelado",
        campus_id: "campus-1",
        campus_name: "Campus Centro",
        institution_id: "inst-1",
        institution_name: "Universidade Nubo",
        city: "Rio de Janeiro",
        state: "RJ",
        opportunity_count: 2,
      }],
      total: 1,
    });
    vi.mocked(getCourseOpportunities).mockResolvedValue([{
      id: "opp-1",
      shift: "Noturno",
      scholarship_type: "Integral",
      concurrency_type: "Ampla concorrência",
      concurrency_tags: [],
      scholarship_tags: [],
      cutoff_score: 710.5,
      year: 2026,
      semester: "1",
      opportunity_type: "prouni",
    }]);

    renderPage(<OpportunitiesCourses />);

    expect(await screen.findByText("Direito")).toBeVisible();
    expect(getCourseOpportunities).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: /Direito/ }));

    expect(await screen.findByText("Noturno")).toBeVisible();
    expect(screen.getByText("710.5")).toBeVisible();
    expect(getCourseOpportunities).toHaveBeenCalledWith({
      courseId: "course-1",
      year: undefined,
      opportunityType: "all",
    });
  });
});
