// NUB-SUP-90 — Clonagem SiSU 2027.1 pela tela de Importação.
// Travam as três causas encontradas no RCA:
//  1. Não existe passo "Herança (Clonagem)" no Pipeline SiSU (só ProUni tem).
//  2. Não existe RPC de clonagem SiSU (só etl_clone_prouni_cycle).
//  3. Os logs globais (Sincronização / e-MEC, program_id NULL) nunca eram lidos:
//     useEtlLogs(null) ficava desabilitado e fetchEtlLogs filtra .eq('program_id', id).
//     O disparo concorrente da Sincronização (lock timeout de 29/10/2026 09:35:26)
//     é travado no banco por advisory lock — ver migration 20261029150000.
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";

const programs = [
  {
    id: "sisu-2027-1",
    title: "SiSU 2027.1",
    cycle_year: 2027,
    cycle_semester: "1",
    status: "incoming",
    type: "sisu",
    prev_program_id: "sisu-2026-1",
    is_fully_imported: false,
  },
  {
    id: "sisu-2026-1",
    title: "SiSU 2026.1",
    cycle_year: 2026,
    cycle_semester: "1",
    status: "inactive",
    type: "sisu",
    prev_program_id: null,
    is_fully_imported: true,
  },
];

const cloneCycle = vi.fn();
const eqSpy = vi.fn();
const isSpy = vi.fn();

vi.mock("@/integrations/supabase/client", () => {
  const builder: any = {
    select: () => builder,
    eq: (...args: unknown[]) => (eqSpy(...args), builder),
    is: (...args: unknown[]) => (isSpy(...args), builder),
    order: () => Promise.resolve({ data: [], error: null }),
  };
  return { supabase: { from: () => builder, rpc: vi.fn() } };
});

describe("NUB-SUP-90 — clonagem SiSU pela tela", () => {
  it("Pipeline SiSU oferece o passo Herança (Clonagem) quando há ciclo anterior", async () => {
    vi.doMock("@/hooks/useEtlPipeline", () => ({
      useActivePrograms: () => ({ data: programs, isLoading: false }),
      useEtlLogs: () => ({ data: [] }),
      useGlobalEtlLogs: () => ({ data: [] }),
      useTriggerEtlStep: () => ({ mutate: vi.fn(), isPending: false }),
      useUpdatePrevCycle: () => ({ mutate: vi.fn() }),
      useCloneCycle: () => ({ mutate: cloneCycle, isPending: false }),
      useStopEtlStep: () => ({ mutate: vi.fn(), isPending: false }),
    }));
    const { default: DataPipeline } = await import("./DataPipeline");
    render(<DataPipeline />);
    fireEvent.change(document.getElementById("sisu-cycle")!, { target: { value: "sisu-2027-1" } });

    // Com a flag em true (estado pós-correção do dado), 2026.1 já aparece; o que falta é o passo.
    expect(within(document.getElementById("sisu-prev-cycle")!).getByRole("option", { name: /SiSU 2026\.1/ })).toBeInTheDocument();
    expect(screen.getAllByText(/Herança \(Clonagem\)/)).toHaveLength(1);
    vi.spyOn(window, "confirm").mockReturnValue(true);
    fireEvent.click(screen.getByRole("button", { name: /Clonar do Ciclo Anterior/ }));
    expect(cloneCycle).toHaveBeenCalledWith({
      programType: "sisu",
      sourceProgramId: "sisu-2026-1",
      targetProgramId: "sisu-2027-1",
    });
    vi.doUnmock("@/hooks/useEtlPipeline");
  });

  const migrations = () => {
    const dir = resolve("supabase/migrations");
    return readdirSync(dir)
      .filter((f) => f.endsWith(".sql"))
      .map((f) => readFileSync(resolve(dir, f), "utf8"));
  };

  it("existe uma RPC de clonagem de ciclo SiSU nas migrations", () => {
    expect(migrations().some((sql) => /FUNCTION\s+(public\.)?etl_clone_sisu_cycle\s*\(/i.test(sql))).toBe(true);
  });

  it("o rollback reconhece a clonagem SiSU", () => {
    expect(migrations().some((sql) => /IN\s*\(\s*'sisu_vacancies'\s*,\s*'sisu_clone'\s*\)/.test(sql))).toBe(true);
  });

  it("a Sincronização recusa disparo concorrente (advisory lock)", () => {
    expect(
      migrations().some((sql) =>
        /FUNCTION\s+public\.etl_import_refresh_opportunities\(\)[\s\S]*pg_try_advisory_xact_lock/.test(sql),
      ),
    ).toBe(true);
  });

  it("logs globais (program_id NULL) são buscados para travar disparo concorrente", async () => {
    const { useGlobalEtlLogs } = await vi.importActual<typeof import("@/hooks/useEtlPipeline")>("@/hooks/useEtlPipeline");
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={client}>{children}</QueryClientProvider>
    );
    renderHook(() => useGlobalEtlLogs(), { wrapper });
    await waitFor(() => expect(isSpy).toHaveBeenCalledWith("program_id", null));
  });
});
