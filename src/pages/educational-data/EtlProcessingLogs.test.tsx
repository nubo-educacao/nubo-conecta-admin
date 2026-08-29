// Contrato dos logs ricos de processamento (etl_run_logs): status, executor,
// duração, detalhes e rollback continuam disponíveis depois de sair da aba
// interna do DataPipeline para um componente irmão.
import { fireEvent, render, screen, within } from "@testing-library/react";

const rollbackStep = vi.fn();
const stopStep = vi.fn();

const logs = [
  {
    id: "log-1",
    program_id: "prouni-2026-1",
    etl_type: "prouni_base",
    status: "error",
    records_processed: 1200,
    errors: 'invalid input syntax for type integer: "1.100"',
    started_at: "2026-08-29T14:08:00.000Z",
    finished_at: "2026-08-29T14:08:16.000Z",
    user_id: null,
    user_name: "brunobogochvol@gmail.com",
    programs: { title: "ProUni 2026.1", cycle_year: 2026, cycle_semester: "1", status: "opened" },
  },
  {
    id: "log-2",
    program_id: null,
    etl_type: "emec",
    status: "running",
    records_processed: 0,
    errors: null,
    started_at: "2026-08-29T15:00:00.000Z",
    finished_at: null,
    user_id: null,
    user_name: null,
    programs: null,
  },
];

vi.mock("@/hooks/useEtlPipeline", () => ({
  useAllEtlLogs: () => ({ data: { data: logs, count: logs.length }, isLoading: false }),
  useRollbackEtlStep: () => ({
    mutate: rollbackStep,
    isPending: false,
    variables: undefined,
    rollbackProgress: null,
  }),
  useStopEtlStep: () => ({ mutate: stopStep, isPending: false, variables: undefined }),
}));

import EtlProcessingLogs, { formatDuration } from "./EtlProcessingLogs";

const rowFor = (label: string) => screen.getByText(label).closest("tr")!;

describe("EtlProcessingLogs", () => {
  beforeEach(() => vi.clearAllMocks());

  it("mostra os detalhes ricos de cada execução", () => {
    render(<EtlProcessingLogs />);

    const row = rowFor("Base ProUni");
    expect(within(row).getByText("ProUni 2026.1")).toBeInTheDocument();
    expect(within(row).getByText("Ciclo: 2026.1")).toBeInTheDocument();
    expect(within(row).getByText("Erro")).toBeInTheDocument();
    expect(within(row).getByText("brunobogochvol@gmail.com")).toBeInTheDocument();
    expect(within(row).getByText("1.200")).toBeInTheDocument();
    expect(within(row).getByText("16s")).toBeInTheDocument();
    expect(within(row).getByText(/invalid input syntax for type integer/)).toBeInTheDocument();
  });

  it("marca execuções globais e em andamento", () => {
    render(<EtlProcessingLogs />);

    const row = rowFor("e-MEC");
    expect(within(row).getByText("Global / Sem ciclo")).toBeInTheDocument();
    expect(within(row).getByText("Sistema")).toBeInTheDocument();
    expect(within(row).getByText("Rodando")).toBeInTheDocument();
    expect(within(row).getByText("Em andamento...")).toBeInTheDocument();
  });

  it("permite parar uma execução em andamento", () => {
    render(<EtlProcessingLogs />);

    fireEvent.click(within(rowFor("e-MEC")).getByRole("button", { name: /Parar execução/ }));
    expect(stopStep).toHaveBeenCalledWith({ logId: "log-2" });
  });

  it("permite rollback de uma importação concluída, com confirmação", () => {
    render(<EtlProcessingLogs />);

    fireEvent.click(within(rowFor("Base ProUni")).getByRole("button"));

    const dialog = screen.getByRole("alertdialog");
    expect(within(dialog).getByRole("heading", { name: "Confirmar Rollback" })).toBeInTheDocument();

    fireEvent.click(within(dialog).getByRole("button", { name: "Confirmar Rollback" }));
    expect(rollbackStep).toHaveBeenCalledWith({ logId: "log-1" });
  });

  it("formata a duração das execuções", () => {
    expect(formatDuration("2026-08-29T14:08:00Z", "2026-08-29T14:08:16Z", "success")).toBe("16s");
    expect(formatDuration("2026-08-29T14:00:00Z", "2026-08-29T14:02:05Z", "success")).toBe("2m 5s");
    expect(formatDuration("2026-08-29T14:00:00Z", null, "running")).toBe("Em andamento...");
    expect(formatDuration("2026-08-29T14:00:00Z", null, "error")).toBe("-");
  });
});
