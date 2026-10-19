// TP-C / NUB-RD-94 — identidade Nubo e navegação do admin.
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DashboardHeader } from "@/components/analytics/DashboardHeader";
import Sidebar from "@/components/layout/Sidebar";
import AdminLayout from "@/components/layout/AdminLayout";

const { auth } = vi.hoisted(() => ({
  auth: {
    session: { user: { id: "admin" } } as { user: { id: string } } | null,
    loading: false,
    permissions: ["Dashboard", "Calendário"],
    signOut: vi.fn(),
  },
}));
vi.mock("@/context/AuthContext", () => ({ useAuth: () => auth }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: vi.fn(), functions: { invoke: vi.fn() } } }));
vi.mock("@/components/analytics/SegmentedExportButton", () => ({ default: () => null }));

afterEach(cleanup);

const root = path.resolve(__dirname, "../..");
const range = { from: new Date("2026-10-01T03:00:00Z"), to: new Date("2026-10-09T03:00:00Z") };

function renderSidebar() {
  return render(
    <MemoryRouter>
      <Sidebar />
    </MemoryRouter>,
  );
}

describe("NUB-RD-94 · título do dashboard", () => {
  it("o cabeçalho do dashboard se chama Command Center", () => {
    render(
      <QueryClientProvider client={new QueryClient()}>
        <DashboardHeader
          selectedRange={range as never}
          onRangeChange={() => {}}
          onRefresh={() => {}}
          isRefreshing={false}
          lastUpdate={new Date("2026-10-19T12:00:00Z")}
        />
      </QueryClientProvider>,
    );
    expect(screen.getByRole("heading", { level: 1, name: "Command Center" })).toBeInTheDocument();
    expect(screen.queryByText("Cloudinha Analytics")).not.toBeInTheDocument();
  });
});

describe("NUB-RD-94 · logo Nubo na navegação", () => {
  it("a Sidebar mostra o logo Nubo (alt=Nubo Conecta) no lugar do texto Nubo Admin", () => {
    renderSidebar();
    const logo = screen.getByAltText("Nubo Conecta");
    expect(logo.tagName).toBe("IMG");
    expect(logo.getAttribute("src")).toMatch(/^\/brand\/nubo-logo/);
    expect(screen.queryByText("Nubo Admin")).not.toBeInTheDocument();
  });

  it("recolhida, a Sidebar mostra só o ícone (favicon) e continua com o alt Nubo Conecta", () => {
    renderSidebar();
    fireEvent.click(screen.getByRole("button", { name: /recolher menu/i }));
    const logo = screen.getByAltText("Nubo Conecta");
    expect(logo.getAttribute("src")).toBe("/favicon.png");
    expect(screen.getByRole("button", { name: /expandir menu/i })).toContainElement(logo);
  });

  it("o header mobile do AdminLayout usa o logo Nubo, não o texto Nubo Admin", () => {
    render(
      <MemoryRouter>
        <AdminLayout />
      </MemoryRouter>,
    );
    const header = screen.getAllByRole("banner")[0];
    expect(within(header).getByAltText("Nubo Conecta")).toBeInTheDocument();
    expect(screen.queryByText("Nubo Admin")).not.toBeInTheDocument();
  });
});

describe("NUB-RD-94 · ordem de Dados Educacionais", () => {
  it("Dashboard MEC é o primeiro item do grupo, sem perder nenhum dos outros", () => {
    renderSidebar();
    fireEvent.click(screen.getByRole("button", { name: /Dados Educacionais/ }));

    const group = screen.getByRole("button", { name: /Dados Educacionais/ }).parentElement as HTMLElement;
    const links = within(group).getAllByRole("link");
    expect(links.map((a) => [a.textContent, a.getAttribute("href")])).toEqual([
      ["Dashboard MEC", "/educational/mec-dashboard"],
      ["Programas & Importação", "/educational/programs-import"],
      ["Instituições & Campus", "/educational/institutions-campus"],
      ["Oportunidades & Cursos", "/educational/opportunities-courses"],
      ["Calendário Educacional", "/calendar"],
    ]);
  });

  it("não remove itens de outras frentes (/analytics segue no menu)", () => {
    renderSidebar();
    // "Visão Geral" já nasce aberto.
    expect(screen.getByRole("link", { name: "Analytics de Produto" })).toHaveAttribute("href", "/analytics");
  });
});

describe("NUB-RD-94 · favicon e ícones", () => {
  const html = readFileSync(path.join(root, "index.html"), "utf8");
  const hrefs = [...html.matchAll(/<link[^>]+rel="(?:icon|apple-touch-icon)"[^>]*>/g)].map((m) => m[0]);
  const ogImage = html.match(/<meta property="og:image" content="([^"]+)"/)?.[1];

  it("declara icon e apple-touch-icon", () => {
    expect(hrefs.some((h) => /rel="icon"/.test(h))).toBe(true);
    expect(hrefs.some((h) => /rel="apple-touch-icon"/.test(h))).toBe(true);
  });

  it("todo href de ícone e o og:image apontam para arquivo existente em public/", () => {
    const targets = hrefs.map((h) => h.match(/href="([^"]+)"/)![1]);
    if (ogImage) targets.push(ogImage);
    expect(targets.length).toBeGreaterThanOrEqual(3);
    for (const t of targets) {
      expect(t.startsWith("/"), `${t} deve ser caminho absoluto do site`).toBe(true);
      expect(existsSync(path.join(root, "public", t)), `public${t} existe`).toBe(true);
    }
  });

  it("o logo da marca está versionado em public/brand (sem dependência cruzada com o app em runtime)", () => {
    expect(existsSync(path.join(root, "public/brand/nubo-logo.png"))).toBe(true);
    expect(html).not.toMatch(/nubo-conecta-app/);
  });
});
