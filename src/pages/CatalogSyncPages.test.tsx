import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import Partners from "./Partners";
import PartnerOpportunities from "./PartnerOpportunities";
import { getPartners, getPartnerStatistics } from "@/services/partnersService";
import {
  listPartnerInstitutionsForSelect,
  listPartnerOpportunities,
} from "@/services/partnerOpportunitiesService";

vi.mock("@/services/partnersService", () => ({
  getPartners: vi.fn(),
  getPartnerStatistics: vi.fn(),
  createPartner: vi.fn(),
  updatePartner: vi.fn(),
  deletePartner: vi.fn(),
}));

vi.mock("@/services/partnerOpportunitiesService", () => ({
  listPartnerOpportunities: vi.fn(),
  listPartnerInstitutionsForSelect: vi.fn(),
  createPartnerOpportunity: vi.fn(),
  updatePartnerOpportunity: vi.fn(),
  updatePartnerOpportunityStatus: vi.fn(),
  deletePartnerOpportunity: vi.fn(),
}));

vi.mock("@/components/partners/PartnerStats", () => ({ PartnerStats: () => null }));
vi.mock("@/components/partners/PartnerTable", () => ({ PartnerTable: () => null }));
vi.mock("@/components/partners/PartnerDialog", () => ({ PartnerDialog: () => null }));
vi.mock("@/components/partners/CatalogSyncButton", () => ({
  CatalogSyncButton: () => <button>Sincronizar Catálogo</button>,
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

describe("atalho de sincronização do catálogo", () => {
  beforeEach(() => {
    vi.mocked(getPartners).mockResolvedValue([]);
    vi.mocked(getPartnerStatistics).mockResolvedValue({} as Awaited<ReturnType<typeof getPartnerStatistics>>);
    vi.mocked(listPartnerOpportunities).mockResolvedValue({ data: [], count: 0 });
    vi.mocked(listPartnerInstitutionsForSelect).mockResolvedValue([]);
  });

  it.each([
    ["Parceiros", <Partners />],
    ["Oportunidades Parceiras", <PartnerOpportunities />],
  ])("exibe o botão em %s", async (_name, page) => {
    renderPage(page);

    expect(
      await screen.findByRole("button", { name: "Sincronizar Catálogo" }),
    ).toBeInTheDocument();
  });
});
