// Página: Pipeline de Importação e Normalização de Dados — Sprint 8.0
// Suporta: SisU Vagas / SisU Aprovados / ProUni Vagas+Ocupação
// Fluxo: Operador seleciona tipo → executa ETL → vê log

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Badge } from "@/components/ui/badge";
import { ScrollArea } from "@/components/ui/scroll-area";
import { triggerEtl } from "@/services/importPipelineService";
import { CheckCircle, XCircle, Loader2, Play } from "lucide-react";

type EtlType = 'prouni_vacancies' | 'sisu_approvals' | 'sisu_vacancies';

interface EtlOption {
  value: EtlType;
  label: string;
  description: string;
  source: string;
  destination: string;
}

const ETL_OPTIONS: EtlOption[] = [
  {
    value: 'prouni_vacancies',
    label: 'ProUni — Vagas + Ocupação',
    description: 'JOIN rawprounivacancies2025 + rawprouniocuppied2025 → tabela normalizada',
    source: 'rawprounivacancies2025 + rawprouniocuppied2025',
    destination: 'opportunities_prouni_vacancies',
  },
  {
    value: 'sisu_approvals',
    label: 'SisU — Aprovados 2026',
    description: 'Agrega rawsisuapprovals2026 por cota (COUNT, MIN, MAX, AVG nota)',
    source: 'rawsisuapprovals2026',
    destination: 'opportunities_sisu_approvals',
  },
  {
    value: 'sisu_vacancies',
    label: 'SisU — Vagas 2026 (re-import)',
    description: 'Re-importa rawsisuvacancies2026 → tabela de vagas SisU',
    source: 'rawsisuvacancies2026',
    destination: 'opportunities_sisu_vacancies',
  },
];

interface RunLog {
  timestamp: string;
  type: EtlType;
  processed: number;
  errors: string[];
  success: boolean;
}

export default function DataPipeline() {
  const [selectedType, setSelectedType] = useState<EtlType>('prouni_vacancies');
  const [isRunning, setIsRunning]       = useState(false);
  const [logs, setLogs]                 = useState<RunLog[]>([]);

  const selectedOption = ETL_OPTIONS.find(o => o.value === selectedType)!;

  const handleRun = async () => {
    setIsRunning(true);
    const params = selectedType === 'sisu_approvals' ? { year: 2026 } : undefined;

    try {
      const result = await triggerEtl(selectedType, params);
      setLogs(prev => [
        {
          timestamp: new Date().toLocaleTimeString('pt-BR'),
          type: selectedType,
          processed: result.processed,
          errors: result.errors,
          success: result.errors.length === 0,
        },
        ...prev,
      ]);
    } catch (err) {
      setLogs(prev => [
        {
          timestamp: new Date().toLocaleTimeString('pt-BR'),
          type: selectedType,
          processed: 0,
          errors: [(err as Error).message],
          success: false,
        },
        ...prev,
      ]);
    } finally {
      setIsRunning(false);
    }
  };

  return (
    <div className="p-6 space-y-6">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Pipeline de Importação MEC</h1>
        <p className="text-muted-foreground">
          Normaliza dados raw (ProUni / SisU) para tabelas estruturadas com FK em opportunities.
        </p>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Painel de Execução */}
        <Card>
          <CardHeader>
            <CardTitle>Executar ETL</CardTitle>
            <CardDescription>
              Selecione o tipo de dado e execute a normalização. O processo
              roda via Edge Function com dados já presentes nas raw tables.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <label className="text-sm font-medium">Tipo de dado</label>
              <Select value={selectedType} onValueChange={v => setSelectedType(v as EtlType)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {ETL_OPTIONS.map(opt => (
                    <SelectItem key={opt.value} value={opt.value}>
                      {opt.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="rounded-md border p-4 space-y-2 bg-muted/40 text-sm">
              <p className="text-muted-foreground">{selectedOption.description}</p>
              <div className="flex flex-col gap-1">
                <span><strong>Fonte:</strong> {selectedOption.source}</span>
                <span><strong>Destino:</strong> {selectedOption.destination}</span>
              </div>
            </div>

            <Button
              className="w-full"
              onClick={handleRun}
              disabled={isRunning}
            >
              {isRunning ? (
                <><Loader2 className="mr-2 h-4 w-4 animate-spin" /> Processando...</>
              ) : (
                <><Play className="mr-2 h-4 w-4" /> Executar ETL</>
              )}
            </Button>
          </CardContent>
        </Card>

        {/* Tabela de Ciclos */}
        <Card>
          <CardHeader>
            <CardTitle>Ciclos Semestrais</CardTitle>
            <CardDescription>Próximas atualizações previstas por tipo de dado.</CardDescription>
          </CardHeader>
          <CardContent>
            <div className="space-y-3 text-sm">
              {[
                { label: 'SisU Vagas',       ciclo: '2026/S1', prox: 'SisU 2026.2 (Jul-Ago 2026)' },
                { label: 'SisU Aprovados',   ciclo: '2026/S1', prox: 'SisU 2026.2 (Jul-Ago 2026)' },
                { label: 'ProUni Vagas+Ocup', ciclo: '2025/S1', prox: 'ProUni 2026.1 (Jan 2027)' },
              ].map(row => (
                <div key={row.label} className="flex items-center justify-between border-b pb-2 last:border-0">
                  <span className="font-medium">{row.label}</span>
                  <div className="flex items-center gap-2">
                    <Badge variant="secondary">{row.ciclo}</Badge>
                    <span className="text-muted-foreground">{row.prox}</span>
                  </div>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>
      </div>

      {/* Log de execuções */}
      {logs.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Log de Execuções</CardTitle>
          </CardHeader>
          <CardContent>
            <ScrollArea className="h-64">
              <div className="space-y-3">
                {logs.map((log, i) => (
                  <div key={i} className="flex items-start gap-3 text-sm border-b pb-3 last:border-0">
                    {log.success ? (
                      <CheckCircle className="h-4 w-4 mt-0.5 text-green-500 flex-shrink-0" />
                    ) : (
                      <XCircle className="h-4 w-4 mt-0.5 text-red-500 flex-shrink-0" />
                    )}
                    <div className="flex-1 space-y-1">
                      <div className="flex items-center gap-2">
                        <span className="font-medium">{ETL_OPTIONS.find(o => o.value === log.type)?.label}</span>
                        <span className="text-muted-foreground">{log.timestamp}</span>
                      </div>
                      <p className="text-muted-foreground">
                        {log.processed} registros processados
                        {log.errors.length > 0 && `, ${log.errors.length} erro(s)`}
                      </p>
                      {log.errors.length > 0 && (
                        <ul className="text-red-600 text-xs space-y-0.5">
                          {log.errors.slice(0, 5).map((e, j) => (
                            <li key={j}>• {e}</li>
                          ))}
                          {log.errors.length > 5 && (
                            <li>• ... e mais {log.errors.length - 5} erro(s)</li>
                          )}
                        </ul>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </ScrollArea>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
