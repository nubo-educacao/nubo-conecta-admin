import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Outlet } from "react-router-dom";
import App from "@/App";
import Sidebar from "@/components/layout/Sidebar";
const { auth } = vi.hoisted(() => ({
  auth: { session: { user: { id: "admin" } } as { user: { id: string } } | null, loading: false, permissions: ["Parceiros"], signOut: vi.fn() },
}));
vi.mock("@/context/AuthContext", () => ({
  useAuth: () => auth,
  AuthProvider: ({ children }: { children: React.ReactNode }) => children,
}));
vi.mock("@/components/layout/AdminLayout", () => ({ default: () => <Outlet /> }));
// Use the real PartnerLayout for its session gate and navigation.
vi.mock("@/components/ui/toaster", () => ({ Toaster: () => null }));
vi.mock("@/components/ui/sonner", () => ({ Toaster: () => null }));
vi.mock("@/pages/Login", () => ({ default: () => <div>Login</div> }));
vi.mock("@/pages/Index", () => ({ default: () => <div>Index</div> }));
vi.mock("@/pages/Analytics", () => ({ default: () => <div>Analytics</div> }));
vi.mock("@/pages/AIInsights", () => ({ default: () => <div>AIInsights</div> }));
vi.mock("@/pages/AppCMS", () => ({ default: () => <div>AppCMS</div> }));
vi.mock("@/pages/Conversas", () => ({ default: () => <div>Conversas</div> }));
vi.mock("@/pages/KnowledgeBase", () => ({ default: () => <div>KnowledgeBase</div> }));
vi.mock("@/pages/AgentConfig", () => ({ default: () => <div>AgentConfig</div> }));
vi.mock("@/pages/MatchEngine", () => ({ default: () => <div>MatchEngine</div> }));
vi.mock("@/pages/AgentTelemetry", () => ({ default: () => <div>AgentTelemetry</div> }));
vi.mock("@/pages/Calendar", () => ({ default: () => <div>Calendar</div> }));
vi.mock("@/pages/educational-data/ProgramsImport", () => ({ default: () => <div>educational-data/ProgramsImport</div> }));
vi.mock("@/pages/educational-data/InstitutionsCampus", () => ({ default: () => <div>educational-data/InstitutionsCampus</div> }));
vi.mock("@/pages/educational-data/OpportunitiesCourses", () => ({ default: () => <div>educational-data/OpportunitiesCourses</div> }));
vi.mock("@/pages/PassportDashboard", () => ({ default: () => <div>PassportDashboard</div> }));
vi.mock("@/pages/MecDashboard", () => ({ default: () => <div>MecDashboard</div> }));
vi.mock("@/pages/ChannelLinks", () => ({ default: () => <div>ChannelLinks</div> }));
vi.mock("@/pages/Channels", () => ({ default: () => <div>Channels</div> }));
vi.mock("@/pages/Partners", () => ({ default: () => <div>Partners</div> }));
vi.mock("@/pages/PartnerSolicitations", () => ({ default: () => <div>PartnerSolicitations</div> }));
vi.mock("@/pages/PartnerForms", () => ({ default: () => <div>PartnerForms</div> }));
vi.mock("@/pages/PartnerUsers", () => ({ default: () => <div>PartnerUsers</div> }));
vi.mock("@/pages/PartnerApplications", () => ({ default: () => <div>PartnerApplications</div> }));
vi.mock("@/pages/PartnerOpportunities", () => ({ default: () => <div>PartnerOpportunities</div> }));
vi.mock("@/pages/FunnelUsers", () => ({ default: () => <div>FunnelUsers</div> }));
vi.mock("@/pages/Students", () => ({ default: () => <div>Students</div> }));
vi.mock("@/pages/Influencers", () => ({ default: () => <div>Influencers</div> }));
vi.mock("@/pages/SeanEllis", () => ({ default: () => <div>SeanEllis</div> }));
vi.mock("@/pages/Users", () => ({ default: () => <div>Users</div> }));
vi.mock("@/pages/Support", () => ({ default: () => <div>Support</div> }));
vi.mock("@/pages/Roadmap", () => ({ default: () => <div>Roadmap</div> }));
vi.mock("@/pages/Docs", () => ({ default: () => <div>Docs</div> }));
vi.mock("@/pages/PartnerPortalForms", () => ({ default: () => <div>PartnerPortalForms</div> }));
vi.mock("@/pages/PartnerDashboard", () => ({ default: () => <div>PartnerDashboard</div> }));
beforeEach(() => {
  auth.session = { user: { id: "admin" } };
  auth.permissions = ["Parceiros"];
  window.history.replaceState({}, "", "/");
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); });
describe("TP-5 standalone funnel retirement", () => {
  it("removes the standalone link and preserves B2B destinations", () => {
    render(<MemoryRouter><Sidebar /></MemoryRouter>);
    fireEvent.click(screen.getByRole("button", { name: "Parceiros & B2B" }));
    expect(screen.queryByRole("link", { name: "Funil de Conversão" })).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Dashboard B2B" })).toHaveAttribute("href", "/b2b-dashboard");
    expect(screen.getByRole("link", { name: "Inscrições Recebidas" })).toHaveAttribute("href", "/applications");
    expect(screen.getByRole("link", { name: "Usuários (Parceiros)" })).toHaveAttribute("href", "/partners-users");
  });
  it("preserves Sidebar permission filtering", () => {
    auth.permissions = [];
    render(<MemoryRouter><Sidebar /></MemoryRouter>);
    expect(screen.queryByRole("button", { name: "Parceiros & B2B" })).not.toBeInTheDocument();
  });
  it.each(["/funnel-users", "/funnel-users?phase=old", "/funnel-users/old"])(
    "sends retired bookmark %s to the existing 404 fallback", (path) => {
      vi.spyOn(console, "error").mockImplementation(() => {});
      window.history.replaceState({}, "", path);
      render(<App />);
      expect(screen.getByRole("heading", { name: "404" })).toBeVisible();
      expect(screen.queryByText("FunnelUsers")).not.toBeInTheDocument();
      expect(screen.getByRole("link", { name: "Return to Home" })).toHaveAttribute("href", "/");
    });
  it.each([
    ["/b2b-dashboard", "PassportDashboard"], ["/partners-users", "PartnerUsers"],
    ["/applications", "PartnerApplications"], ["/partner", "PartnerDashboard"],
    ["/partner/forms", "PartnerPortalForms"],
  ])("preserves %s and its page", (path, page) => {
    window.history.replaceState({}, "", path);
    render(<App />);
    expect(screen.getByText(page)).toBeVisible();
    expect(screen.queryByRole("heading", { name: "404" })).not.toBeInTheDocument();
  });
  it("preserves portal navigation", () => {
    window.history.replaceState({}, "", "/partner"); render(<App />);
    expect(screen.getByRole("link", { name: "Candidaturas" })).toHaveAttribute("href", "/partner");
    expect(screen.getByRole("link", { name: "Formulários" })).toHaveAttribute("href", "/partner/forms");
  });
  it("keeps unauthenticated portal bookmarks behind login", () => {
    auth.session = null;
    window.history.replaceState({}, "", "/partner"); render(<App />);
    expect(screen.getByText("Login")).toBeVisible();
    expect(screen.queryByText("PartnerDashboard")).not.toBeInTheDocument();
  });
  // NUB-RD-89a: o item "Analytics de Produto" existia na Sidebar desde a Sprint 1 e caía no 404.
  it("abre /analytics para quem tem Dashboard, sem cair no 404", () => {
    auth.permissions = ["Dashboard"];
    window.history.replaceState({}, "", "/analytics?campaignId=x");
    render(<App />);
    expect(screen.getByText("Analytics")).toBeVisible();
    expect(screen.queryByRole("heading", { name: "404" })).not.toBeInTheDocument();
  });
  it("não concede /analytics a quem não tem Dashboard", () => {
    auth.permissions = ["Parceiros"];
    window.history.replaceState({}, "", "/analytics");
    render(<App />);
    expect(screen.queryByText("Analytics")).not.toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("Você não tem permissão para acessar esta página.");
  });
  it("o link da Sidebar (grupo Visão Geral aberto por padrão) aponta para a rota registrada", () => {
    auth.permissions = ["Dashboard"];
    render(<MemoryRouter><Sidebar /></MemoryRouter>);
    expect(screen.getByRole("link", { name: "Analytics de Produto" })).toHaveAttribute("href", "/analytics");
  });
});
