import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { getPartnerFunnel } from "@/services/passportDashboardService";

vi.mock("@/services/partnerPortalService", () => ({
  getMyPartnerId: vi.fn(async () => "inst-ponte"),
  getPartnerDetails: vi.fn(async () => ({ name: "Ponte" })),
  getPartnerRedirectUsers: vi.fn(async () => []),
  getPartnerOpportunities: vi.fn(async () => []),
}));
vi.mock("@/services/applicationsService", () => ({
  getApplicationsByInstitution: vi.fn(async () => []),
  getEligibleCountByInstitution: vi.fn(async () => 0),
  getPartnerFormFieldsMap: vi.fn(async () => ({})),
  getOpportunityPhases: vi.fn(async () => []),
  updateApplicationPhase: vi.fn(),
  updateApplicationsPhaseBulk: vi.fn(),
}));
vi.mock("@/services/passportDashboardService", () => ({ getPartnerFunnel: vi.fn() }));
vi.mock("@/components/applications/ApplicationsTable", () => ({ default: () => null }));
vi.mock("@/components/applications/RedirectUsersTable", () => ({ default: () => null }));
vi.mock("@/components/applications/ApplicationAnswersModal", () => ({ default: () => null }));
vi.mock("@/components/applications/BulkCsvImportModal", () => ({ default: () => null }));
import PartnerDashboard from "@/pages/PartnerDashboard";

afterEach(cleanup);

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={client}><PartnerDashboard /></QueryClientProvider>);
}

describe("Partner portal funnel (v2, no regression)", () => {
  it("asks v2 for its own institution over all time and keeps total_unique_clicks", async () => {
    // The RPC itself scopes partners_users to their institution (42501/empty otherwise);
    // the portal never asks for another institution or for "all".
    vi.mocked(getPartnerFunnel).mockResolvedValue([
      { partner_id: "inst-ponte", partner_name: "Ponte", total_unique_clicks: 30, total_applications_started: 99, total_applications_completed: 95, total_card_clicks: 44, legacy_external_redirects: 0, last_activity_at: "2026-03-31T12:00:00Z" },
    ]);
    renderPage();
    expect(await screen.findByText("30")).toBeInTheDocument();
    expect(screen.getByText("Cliques no Perfil")).toBeInTheDocument();
    expect(getPartnerFunnel).toHaveBeenCalledTimes(1);
    expect(getPartnerFunnel).toHaveBeenCalledWith("inst-ponte", {});
  });

  it("ignores rows of other institutions even if they ever came back", async () => {
    vi.mocked(getPartnerFunnel).mockResolvedValue([
      { partner_id: "inst-other", partner_name: "Outra", total_unique_clicks: 999, total_applications_started: 0, total_applications_completed: 0, total_card_clicks: 0, legacy_external_redirects: 0, last_activity_at: null },
    ]);
    renderPage();
    await screen.findByText("Cliques no Perfil");
    expect(screen.queryByText("999")).not.toBeInTheDocument();
  });
});
