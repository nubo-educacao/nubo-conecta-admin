import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { EDUCATIONAL_NAV_ITEMS } from "@/components/layout/educationalNavigation";
import ProgramsImport from "./ProgramsImport";

vi.mock("@/pages/Programs", () => ({
  default: () => <div>Gestão de programas preservada</div>,
}));

vi.mock("./DataPipeline", () => ({
  default: () => <div>Pipeline ETL preservado</div>,
}));

vi.mock("./Institutions", () => ({
  default: () => <div>Uploads e logs persistentes preservados</div>,
}));

function renderPage() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <ProgramsImport />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("navegação educacional agrupada", () => {
  it("expõe exatamente as três entradas canônicas da ADR-0026", () => {
    expect(EDUCATIONAL_NAV_ITEMS).toEqual([
      {
        to: "/educational/programs-import",
        label: "Programas & Importação",
      },
      {
        to: "/educational/institutions-campus",
        label: "Instituições & Campus",
      },
      {
        to: "/educational/opportunities-courses",
        label: "Oportunidades & Cursos",
      },
    ]);
  });

  it("preserva programas, pipeline, uploads e logs dentro de duas abas", () => {
    renderPage();

    expect(screen.getByRole("tab", { name: "Programas" })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "Importação" })).toBeInTheDocument();
    expect(screen.getByText("Gestão de programas preservada")).toBeVisible();

    fireEvent.mouseDown(screen.getByRole("tab", { name: "Importação" }));
    fireEvent.click(screen.getByRole("tab", { name: "Importação" }));

    expect(screen.getByText("Pipeline ETL preservado")).toBeVisible();
    expect(screen.getByText("Uploads e logs persistentes preservados")).toBeVisible();
  });
});
