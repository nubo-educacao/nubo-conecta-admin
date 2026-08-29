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

vi.mock("./EtlProcessingLogs", () => ({
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

  it("preserva programas, pipeline e logs em um único nível de abas", () => {
    renderPage();

    // Três abas irmãs — nada de abas dentro de abas.
    expect(screen.getAllByRole("tab").map((t) => t.textContent)).toEqual([
      "Programas",
      "Importação (ETL)",
      "Logs de Processamento",
    ]);
    expect(screen.getByText("Gestão de programas preservada")).toBeVisible();

    openTab("Importação (ETL)");
    expect(screen.getByText("Pipeline ETL preservado")).toBeVisible();
    expect(screen.queryAllByRole("tab")).toHaveLength(3);

    openTab("Logs de Processamento");
    expect(screen.getByText("Uploads e logs persistentes preservados")).toBeVisible();
    expect(screen.queryAllByRole("tab")).toHaveLength(3);
  });
});

function openTab(name: string) {
  const tab = screen.getByRole("tab", { name });
  fireEvent.mouseDown(tab);
  fireEvent.click(tab);
}
