import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { toast } from "sonner";
import PartnerLayout from "@/components/layout/PartnerLayout";
import { useAuth } from "@/context/AuthContext";
import { triggerEtlStep } from "@/services/etlPipelineService";
import { CatalogSyncButton } from "./CatalogSyncButton";

vi.mock("@/context/AuthContext", () => ({ useAuth: vi.fn() }));
vi.mock("@/services/etlPipelineService", () => ({ triggerEtlStep: vi.fn() }));
vi.mock("sonner", () => ({
  toast: {
    loading: vi.fn(),
    success: vi.fn(),
    error: vi.fn(),
  },
}));

function authValue(userRole: string): ReturnType<typeof useAuth> {
  return {
    session: { user: { id: "user-1" } },
    user: { id: "user-1" },
    userRole,
    permissions: [],
    loading: false,
    signOut: vi.fn(),
  } as unknown as ReturnType<typeof useAuth>;
}

function renderButton() {
  const queryClient = new QueryClient({
    defaultOptions: { mutations: { retry: false } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <CatalogSyncButton />
    </QueryClientProvider>,
  );
}

describe("CatalogSyncButton", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(useAuth).mockReturnValue(authValue("authenticated"));
  });

  it("dispara exclusivamente refresh_opportunities e bloqueia o botão durante o refresh", async () => {
    let finish!: (value: { processed: number; errors: string[] }) => void;
    vi.mocked(triggerEtlStep).mockImplementation(
      () => new Promise((resolve) => { finish = resolve; }),
    );
    renderButton();

    const button = screen.getByRole("button", { name: "Sincronizar Catálogo" });
    fireEvent.click(button);

    await waitFor(() => expect(triggerEtlStep).toHaveBeenCalledTimes(1));
    expect(triggerEtlStep).toHaveBeenCalledWith("refresh_opportunities");
    await waitFor(() => expect(button).toBeDisabled());
    expect(toast.loading).toHaveBeenCalled();

    finish({ processed: 0, errors: [] });

    await waitFor(() => expect(button).not.toBeDisabled());
    expect(toast.success).toHaveBeenCalled();
  });

  it("exibe toast de erro quando a sincronização falha", async () => {
    vi.mocked(triggerEtlStep).mockRejectedValue(new Error("refresh indisponível"));
    renderButton();

    fireEvent.click(screen.getByRole("button", { name: "Sincronizar Catálogo" }));

    await waitFor(() => expect(toast.error).toHaveBeenCalled());
  });

  it("não permite que um parceiro veja ou dispare a sincronização no PartnerLayout", () => {
    vi.mocked(useAuth).mockReturnValue(authValue("partner"));
    const queryClient = new QueryClient();

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/partner"]}>
          <Routes>
            <Route element={<PartnerLayout />}>
              <Route path="/partner" element={<CatalogSyncButton />} />
            </Route>
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>,
    );

    expect(screen.queryByRole("button", { name: "Sincronizar Catálogo" })).not.toBeInTheDocument();
    expect(triggerEtlStep).not.toHaveBeenCalled();
  });
});
