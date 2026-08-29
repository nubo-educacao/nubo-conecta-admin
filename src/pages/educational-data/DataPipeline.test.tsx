// Contrato da tela de Importação (ETL).
// Trava o end-state da fusão: o design shadcn (Card + Fonte/Destino + Badge) que
// existia antes do #46, com os controles reais do pipeline. Os logs ficam em
// EtlProcessingLogs.test.tsx — são um componente irmão, não uma aba interna.
import { fireEvent, render, screen, within } from "@testing-library/react";

const triggerStep = vi.fn();
const cloneCycle = vi.fn();
const updatePrevCycle = vi.fn();
const stopStep = vi.fn();

const programs = [
  {
    id: "prouni-2026-1",
    title: "ProUni 2026.1",
    cycle_year: 2026,
    cycle_semester: "1",
    status: "opened",
    type: "prouni",
    prev_program_id: "prouni-2025-2",
    is_fully_imported: false,
  },
  {
    id: "prouni-2025-2",
    title: "ProUni 2025.2",
    cycle_year: 2025,
    cycle_semester: "2",
    status: "closed",
    type: "prouni",
    prev_program_id: null,
    is_fully_imported: true,
  },
  {
    id: "sisu-2026-1",
    title: "SiSU 2026.1",
    cycle_year: 2026,
    cycle_semester: "1",
    status: "opened",
    type: "sisu",
    prev_program_id: null,
    is_fully_imported: false,
  },
];

let prouniLogs: any[] = [];

vi.mock("@/hooks/useEtlPipeline", () => ({
  useActivePrograms: () => ({ data: programs, isLoading: false }),
  useEtlLogs: (programId: string | null) => ({ data: programId === "prouni-2026-1" ? prouniLogs : [] }),
  useTriggerEtlStep: () => ({ mutate: triggerStep, isPending: false }),
  useUpdatePrevCycle: () => ({ mutate: updatePrevCycle }),
  useCloneCycle: () => ({ mutate: cloneCycle, isPending: false }),
  useStopEtlStep: () => ({ mutate: stopStep, isPending: false, variables: undefined }),
}));

import DataPipeline from "./DataPipeline";

const selectCycle = (labelId: string, value: string) =>
  fireEvent.change(document.getElementById(labelId)!, { target: { value } });

describe("DataPipeline — tela de Importação (ETL)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    prouniLogs = [];
  });

  it("não renderiza abas próprias — o aninhamento de abas foi eliminado", () => {
    render(<DataPipeline />);
    expect(screen.queryAllByRole("tab")).toHaveLength(0);
  });

  it("mostra os quatro pipelines com origem e destino de cada passo", () => {
    render(<DataPipeline />);

    expect(screen.getByText("Pipeline ProUni")).toBeInTheDocument();
    expect(screen.getByText("Pipeline SiSU")).toBeInTheDocument();
    expect(screen.getByText("Pipeline e-MEC")).toBeInTheDocument();
    expect(screen.getByText("Sincronização")).toBeInTheDocument();

    // e-MEC e Sincronização são globais: aparecem sem selecionar ciclo.
    expect(screen.getByText("rawemec")).toBeInTheDocument();
    expect(screen.getByText("institutions_info_emec")).toBeInTheDocument();
    expect(screen.getByText("v_unified_opportunities")).toBeInTheDocument();
  });

  it("dispara a ingestão ProUni para o ciclo selecionado", () => {
    render(<DataPipeline />);

    selectCycle("prouni-cycle", "prouni-2026-1");
    expect(screen.getByText("rawprouni")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Importar Base \+ Vagas/ }));

    expect(triggerStep).toHaveBeenCalledWith(
      expect.objectContaining({ step: "prouni_base", programId: "prouni-2026-1" }),
    );
  });

  it("mantém o fluxo de herança (clonagem) do ciclo anterior", () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<DataPipeline />);

    selectCycle("prouni-cycle", "prouni-2026-1");
    fireEvent.click(screen.getByRole("button", { name: /Clonar do Ciclo Anterior/ }));

    expect(cloneCycle).toHaveBeenCalledWith({
      sourceProgramId: "prouni-2025-2",
      targetProgramId: "prouni-2026-1",
    });
    confirmSpy.mockRestore();
  });

  it("mantém os dois passos do SiSU e a orientação de ciclo anterior", () => {
    render(<DataPipeline />);

    selectCycle("sisu-cycle", "sisu-2026-1");

    expect(screen.getByText(/Vagas Ofertadas \(Termo de Adesão\)/)).toBeInTheDocument();
    expect(screen.getByText(/Base Consolidada \(Notas de Corte\)/)).toBeInTheDocument();
    expect(screen.getAllByText(/deve ter completado toda a importação \(is_fully_imported\)/).length).toBeGreaterThan(0);

    fireEvent.click(screen.getByRole("button", { name: /Importar Termo de Adesão \(Vagas\)/ }));
    expect(triggerStep).toHaveBeenCalledWith(
      expect.objectContaining({ step: "sisu_vacancies", programId: "sisu-2026-1" }),
    );
  });

  it("mantém os disparos globais de e-MEC e sincronização de views", () => {
    render(<DataPipeline />);

    fireEvent.click(screen.getByRole("button", { name: /Importar Metadados/ }));
    expect(triggerStep).toHaveBeenCalledWith(expect.objectContaining({ step: "emec" }));

    fireEvent.click(screen.getByRole("button", { name: /Atualizar/ }));
    expect(triggerStep).toHaveBeenCalledWith(expect.objectContaining({ step: "refresh_opportunities" }));
  });

  it("troca o disparo por 'Parar Execução' enquanto o passo está rodando", () => {
    prouniLogs = [{ id: "log-running", etl_type: "prouni_base", status: "running" }];
    render(<DataPipeline />);

    selectCycle("prouni-cycle", "prouni-2026-1");

    const box = screen.getByText("1. Importação Unificada").closest("div")!.parentElement!;
    expect(within(box).getByText(/Rodando/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /Parar Execução/ }));
    expect(stopStep).toHaveBeenCalledWith({ logId: "log-running" });
    expect(triggerStep).not.toHaveBeenCalled();
  });

  it("grava o ciclo anterior escolhido no programa", () => {
    render(<DataPipeline />);

    selectCycle("prouni-cycle", "prouni-2026-1");
    selectCycle("prouni-prev-cycle", "prouni-2025-2");

    expect(updatePrevCycle).toHaveBeenCalledWith({
      programId: "prouni-2026-1",
      prevProgramId: "prouni-2025-2",
    });
  });
});
