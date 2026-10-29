// NUB-RD-100 — governança do Snaps com o snaps-client 0.2.0.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import Sidebar from "@/components/layout/Sidebar";
import Costs from "@/pages/Costs";
import { SNAPS_PROJECT_ID, SNAPS_PROXY_URL } from "@/lib/snapsProxyClient";

const { auth } = vi.hoisted(() => ({
  auth: {
    session: { user: { id: "admin" }, access_token: "token-da-sessao-sentinela" },
    loading: false,
    permissions: ["Dashboard"],
    signOut: vi.fn(),
  },
}));
vi.mock("@/context/AuthContext", () => ({ useAuth: () => auth }));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { auth: { getSession: vi.fn() } } }));

afterEach(cleanup);

const BUNDLE = path.resolve(__dirname, "../../public/snaps/snaps-client.umd.js");

describe("bundle do snaps-client", () => {
  // SHA256 do manifest do artifact oficial snaps-client-0.2.0-67edd0e7 (run 40957512016).
  it("é o UMD 0.2.0 oficial, byte a byte", () => {
    const sha = createHash("sha256").update(readFileSync(BUNDLE)).digest("hex");
    expect(sha).toBe("a058959c8d03ac6e4f1fb772f98d0725f3a882878ca7fd0badfe197873dc8797");
  });

  it("expõe SnapsClient.version === '0.2.0' e registra <snaps-costs-board>", () => {
    (0, eval)(readFileSync(BUNDLE, "utf8"));
    const g = globalThis as unknown as { SnapsClient?: { version?: string } };
    expect(g.SnapsClient?.version).toBe("0.2.0");
    expect(customElements.get("snaps-costs-board")).toBeDefined();
  });
});

describe("página Custos", () => {
  it("usa <snaps-costs-board> pelo proxy /api/snaps, com o token da sessão e sem chave", () => {
    const { container } = render(<Costs />);
    const board = container.querySelector("snaps-costs-board");
    expect(board).not.toBeNull();
    expect(board!.getAttribute("project-id")).toBe(SNAPS_PROJECT_ID);
    expect(board!.getAttribute("api-url")).toBe(SNAPS_PROXY_URL);
    expect(SNAPS_PROXY_URL).toBe("/api/snaps");
    expect(board!.getAttribute("api-key")).toBe("token-da-sessao-sentinela");
    expect(screen.getByRole("heading", { name: "Custos" })).toBeInTheDocument();
  });
});

describe("menu de Governança", () => {
  it("tem o item Custos apontando para /governance/costs", () => {
    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );
    fireEvent.click(screen.getByRole("button", { name: "Governança" }));
    expect(screen.getByRole("link", { name: "Custos" })).toHaveAttribute("href", "/governance/costs");
  });
});
