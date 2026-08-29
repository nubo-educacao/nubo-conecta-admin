// Contrato da tela unificada de Importações (ETL).
// A Sprint 9.0 fundiu <ImportPipelineControl /> + a aba de logs de <Institutions embedded />
// dentro de DataPipeline. Estes testes travam o end-state: um único componente precisa
// entregar seleção de ciclo, disparo de ingestão, clonagem, status em tempo real,
// histórico de etl_run_logs e rollback.
import { fireEvent, render, screen, within } from "@testing-library/react";

const triggerStep = vi.fn();
const cloneCycle = vi.fn();
const updatePrevCycle = vi.fn();
const rollbackStep = vi.fn();
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
  {
    id: "sisu-2025-1",
    title: "SiSU 2025.1",
    cycle_year: 2025,
    cycle_semester: "1",
    status: "closed",
    type: "sisu",
    prev_program_id: null,
    is_fully_imported: true,
  },
];

const allLogs = [
  {
    id: "log-1",
    program_id: "prouni-2026-1",
    etl_type: "prouni_base",
    status: "error",
    records_processed: 1200,
    errors: 'constraint "uq_opportunities_prouni_concurrency" does not exist',
    started_at: "2026-08-28T12:00:00.000Z",
    finished_at: "2026-08-28T12:01:00.000Z",
    user_id: null,
    user_name: "Bruno",
    programs: { title: "ProUni 2026.1", cycle_year: 2026, cycle_semester: "1", status: "opened" },
  },
];

vi.mock("@/hooks/useEtlPipeline", () => ({
  useActivePrograms: () => ({ data: programs, isLoading: false }),
  useEtlLogs: () => ({ data: [] }),
  useAllEtlLogs: () => ({ data: { data: allLogs, count: allLogs.length }, isLoading: false }),
  useTriggerEtlStep: () => ({ mutate: triggerStep, isPending: false }),
  useUpdatePrevCycle: () => ({ mutate: updatePrevCycle }),
  useCloneCycle: () => ({ mutate: cloneCycle, isPending: false }),
  useStopEtlStep: () => ({ mutate: stopStep, isPending: false, variables: undefined }),
  useRollbackEtlStep: () => ({
    mutate: rollbackStep,
    isPending: false,
    variables: undefined,
    rollbackProgress: null,
  }),
}));

import DataPipeline from "./DataPipeline";

function selectCycle(comboboxIndex: number, value: string) {
  const selects = screen.getAllByRole("combobox");
  fireEvent.change(selects[comboboxIndex], { target: { value } });
}

function openTab(name: RegExp) {
  const tab = screen.getByRole("tab", { name });
  fireEvent.mouseDown(tab);
  fireEvent.click(tab);
}

describe("DataPipeline — tela unificada de ETL", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("expõe as duas abas do componente fundido", () => {
    render(<DataPipeline />);

    expect(screen.getByRole("tab", { name: /Importações \(ETL\)/ })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /Logs de Processamento/ })).toBeInTheDocument();
  });

  it("dispara a ingestão ProUni para o ciclo selecionado", () => {
    render(<DataPipeline />);

    selectCycle(0, "prouni-2026-1");
    fireEvent.click(screen.getByRole("button", { name: /Importar Base \+ Vagas/ }));

    expect(triggerStep).toHaveBeenCalledWith(
      expect.objectContaining({ step: "prouni_base", programId: "prouni-2026-1" }),
    );
  });

  it("mantém o fluxo de herança (clonagem) do ciclo anterior", () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<DataPipeline />);

    selectCycle(0, "prouni-2026-1");
    fireEvent.click(screen.getByRole("button", { name: /Clonar do Ciclo Anterior/ }));

    expect(cloneCycle).toHaveBeenCalledWith({
      sourceProgramId: "prouni-2025-2",
      targetProgramId: "prouni-2026-1",
    });
    confirmSpy.mockRestore();
  });

  it("mantém os dois passos do SiSU e a orientação de ciclo anterior", () => {
    render(<DataPipeline />);

    selectCycle(1, "sisu-2026-1");

    expect(screen.getByText(/Vagas Ofertadas \(Termo de Adesão\)/)).toBeInTheDocument();
    expect(screen.getByText(/Base Consolidada \(Notas de Corte\)/)).toBeInTheDocument();
    expect(
      screen.getByText(/deve ter completado toda a importação \(is_fully_imported\)/),
    ).toBeInTheDocument();

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
    expect(triggerStep).toHaveBeenCalledWith(
      expect.objectContaining({ step: "refresh_opportunities" }),
    );
  });

  it("mostra o histórico de etl_run_logs com detalhes e ação de rollback", () => {
    render(<DataPipeline />);
    openTab(/Logs de Processamento/);

    const row = screen.getByText("Base ProUni").closest("tr")!;
    expect(within(row).getByText("Erro")).toBeInTheDocument();
    expect(within(row).getByText(/uq_opportunities_prouni_concurrency/)).toBeInTheDocument();
    expect(within(row).getByText("1.200")).toBeInTheDocument();

    fireEvent.click(within(row).getByRole("button"));
    const dialog = screen.getByRole("alertdialog");
    expect(within(dialog).getByRole("heading", { name: "Confirmar Rollback" })).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Confirmar Rollback" }));
    expect(rollbackStep).toHaveBeenCalledWith({ logId: "log-1" });
  });
});
