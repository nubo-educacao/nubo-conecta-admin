import React, { useState } from 'react';
import { useActivePrograms, useEtlLogs, useTriggerEtlStep, useUpdatePrevCycle } from '@/hooks/useEtlPipeline';
import { EtlStepType, Program } from '@/services/etlPipelineService';
import { Play, CheckCircle2, XCircle, Clock, Loader2, Database } from 'lucide-react';

export default function ImportPipelineControl() {
  const { data: programs, isLoading: isLoadingPrograms } = useActivePrograms();
  const [selectedProuniId, setSelectedProuniId] = useState<string | null>(null);
  const [selectedSisuId, setSelectedSisuId] = useState<string | null>(null);

  const { data: prouniLogs } = useEtlLogs(selectedProuniId);
  const { data: sisuLogs } = useEtlLogs(selectedSisuId);
  const { data: globalLogs } = useEtlLogs(null);

  const { mutate: triggerStep, isPending } = useTriggerEtlStep();
  const { mutate: updatePrevCycle } = useUpdatePrevCycle();

  const handlePrevCycleChange = (programId: string, prevProgramId: string) => {
    updatePrevCycle({ programId, prevProgramId: prevProgramId || null });
  };

  const getStepStatus = (step: EtlStepType, logs: any[] | undefined) => {
    if (!logs) return null;
    return logs.find((l) => l.etl_type === step)?.status || null;
  };

  const isStepSuccess = (step: EtlStepType, logs: any[] | undefined) => getStepStatus(step, logs) === 'success';

  const [progressMap, setProgressMap] = useState<Record<string, { pct: number }>>({});

  const handleTrigger = (step: EtlStepType, programId: string | null) => {
    if (!programId && !['emec', 'refresh_opportunities', 'refresh_catalog'].includes(step)) return;
    
    setProgressMap(prev => ({ ...prev, [step]: { pct: 0 } }));
    
    triggerStep({ 
      step, 
      programId: programId || undefined,
      onProgress: (processed, total) => {
        const pct = total > 0 ? Math.round((processed / total) * 100) : 0;
        setProgressMap(prev => ({ ...prev, [step]: { pct } }));
      }
    });
  };

  const renderStatusBadge = (step: EtlStepType, logs: any[] | undefined) => {
    const status = getStepStatus(step, logs);
    if (status === 'success') return <span className="flex items-center text-green-600 text-sm font-medium"><CheckCircle2 className="w-4 h-4 mr-1"/> Importado</span>;
    if (status === 'error') return <span className="flex items-center text-red-600 text-sm font-medium"><XCircle className="w-4 h-4 mr-1"/> Erro</span>;
    if (status === 'running') {
      const prog = progressMap[step];
      const displayPct = prog ? ` ${prog.pct}%` : '';
      return <span className="flex items-center text-blue-600 text-sm font-medium animate-pulse"><Loader2 className="w-4 h-4 mr-1 animate-spin"/> Rodando...{displayPct}</span>;
    }
    return <span className="flex items-center text-gray-400 text-sm font-medium"><Clock className="w-4 h-4 mr-1"/> Não executado</span>;
  };

  const [elapsed, setElapsed] = useState(0);

  React.useEffect(() => {
    let interval: NodeJS.Timeout;
    if (isPending) {
      interval = setInterval(() => setElapsed((e) => e + 1), 1000);
    } else {
      setElapsed(0);
    }
    return () => clearInterval(interval);
  }, [isPending]);

  const renderButton = (step: EtlStepType, label: string, disabled: boolean, programId: string | null, logs: any[] | undefined) => {
    const status = getStepStatus(step, logs);
    const isRunning = status === 'running' || isPending;

    return (
      <button
        onClick={() => handleTrigger(step, programId)}
        disabled={disabled || isRunning}
        className={`flex items-center justify-between w-full px-4 py-3 rounded-lg border text-sm font-medium transition-colors mt-2 ${
          disabled || isRunning
            ? 'bg-gray-50 border-gray-200 text-gray-400 cursor-not-allowed'
            : 'bg-white border-blue-200 text-blue-700 hover:bg-blue-50 hover:border-blue-300'
        }`}
      >
        <span className="flex items-center">
          {label}
          {isRunning && elapsed > 0 && <span className="ml-2 text-xs font-normal opacity-70">({elapsed}s)</span>}
          {isRunning && progressMap[step] !== undefined && <span className="ml-2 text-xs font-bold text-blue-600">{progressMap[step].pct}%</span>}
        </span>
        {isRunning ? <Loader2 className="w-4 h-4 animate-spin" /> : <Play className="w-4 h-4" />}
      </button>
    );
  };

  const prouniPrograms = programs?.filter(p => p.type === 'prouni') || [];
  const sisuPrograms = programs?.filter(p => p.type === 'sisu') || [];

  return (
    <div className="w-full space-y-8">
      <div className="flex flex-col gap-2">
        <h1 className="text-2xl font-bold text-gray-900">Importação de Dados MEC (ETL)</h1>
        <p className="text-gray-500 text-sm max-w-4xl">
          Instruções operacionais: Certifique-se de que o CSV correspondente foi previamente carregado na sua respectiva tabela <code className="bg-gray-100 px-1 py-0.5 rounded text-gray-800">staging</code> no banco de dados via DBeaver/PgAdmin. Após o upload, selecione o ciclo abaixo e clique em importar para processar os dados e unificá-los ao catálogo do Nubo.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-4 gap-6 items-start">
        {/* PROUNI PIPELINE */}
        <div className="bg-white p-6 rounded-xl border border-gray-200 shadow-sm space-y-6">
          <div className="border-b pb-4">
            <h3 className="text-lg font-bold text-gray-900 flex items-center">
              <Database className="w-5 h-5 mr-2 text-blue-600" />
              Pipeline ProUni
            </h3>
            <p className="text-xs text-gray-500 mt-1">Integração de Base, Vagas e Ocupação.</p>
          </div>

          <div className="space-y-2">
            <label className="text-sm font-semibold text-gray-700">Selecione o Ciclo (Contexto)</label>
            <select
              value={selectedProuniId || ''}
              onChange={(e) => setSelectedProuniId(e.target.value)}
              className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <option value="">-- Escolha um ciclo ProUni --</option>
              {prouniPrograms.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.title} ({p.cycle_year}.{p.cycle_semester}) - {p.status}
                </option>
              ))}
            </select>
          </div>

          {selectedProuniId && (
            <div className="space-y-2 mt-4">
              <label className="text-sm font-semibold text-gray-700">Ciclo Anterior (Comparação Opcional)</label>
              <select
                value={prouniPrograms.find(p => p.id === selectedProuniId)?.prev_program_id || ''}
                onChange={(e) => handlePrevCycleChange(selectedProuniId, e.target.value)}
                className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-blue-500"
              >
                <option value="">-- Sem ciclo anterior (ocultar comparação) --</option>
                {prouniPrograms
                  .filter((p) => p.id !== selectedProuniId && p.is_fully_imported)
                  .map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.title} ({p.cycle_year}.{p.cycle_semester}) - {p.status}
                    </option>
                  ))}
              </select>
              <p className="text-xs text-gray-500">
                O ciclo listado acima deve ter completado toda a importação (is_fully_imported).
              </p>
            </div>
          )}

          {selectedProuniId && (
            <div className="space-y-4 pt-2">
              <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                <div className="flex justify-between items-start mb-1">
                  <div>
                    <span className="text-sm font-semibold text-slate-800">1. Base de Dados</span>
                    <p className="text-xs text-slate-500 font-mono mt-1">Tabela: rawprouni</p>
                  </div>
                  {renderStatusBadge('prouni_base', prouniLogs)}
                </div>
                {renderButton('prouni_base', 'Importar Base ProUni', false, selectedProuniId, prouniLogs)}
              </div>

              <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                <div className="flex justify-between items-start mb-1">
                  <div>
                    <span className="text-sm font-semibold text-slate-800">2. Vagas</span>
                    <p className="text-xs text-slate-500 font-mono mt-1">Tabela: rawprounivacancies</p>
                  </div>
                  {renderStatusBadge('prouni_vacancies', prouniLogs)}
                </div>
                {renderButton('prouni_vacancies', 'Importar Vagas', !isStepSuccess('prouni_base', prouniLogs), selectedProuniId, prouniLogs)}
              </div>

              <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                <div className="flex justify-between items-start mb-1">
                  <div>
                    <span className="text-sm font-semibold text-slate-800">3. Ocupação</span>
                    <p className="text-xs text-slate-500 font-mono mt-1">Tabela: rawprouniocuppied</p>
                  </div>
                  {renderStatusBadge('prouni_occupied', prouniLogs)}
                </div>
                {renderButton('prouni_occupied', 'Importar Ocupação', !isStepSuccess('prouni_vacancies', prouniLogs), selectedProuniId, prouniLogs)}
              </div>
            </div>
          )}
        </div>

        {/* SISU PIPELINE */}
        <div className="bg-white p-6 rounded-xl border border-gray-200 shadow-sm space-y-6">
          <div className="border-b pb-4">
            <h3 className="text-lg font-bold text-gray-900 flex items-center">
              <Database className="w-5 h-5 mr-2 text-green-600" />
              Pipeline SiSU
            </h3>
            <p className="text-xs text-gray-500 mt-1">Integração de Base e Vagas.</p>
          </div>

          <div className="space-y-2">
            <label className="text-sm font-semibold text-gray-700">Selecione o Ciclo (Contexto)</label>
            <select
              value={selectedSisuId || ''}
              onChange={(e) => setSelectedSisuId(e.target.value)}
              className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-green-500"
            >
              <option value="">-- Escolha um ciclo SiSU --</option>
              {sisuPrograms.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.title} ({p.cycle_year}.{p.cycle_semester}) - {p.status}
                </option>
              ))}
            </select>
          </div>

          {selectedSisuId && (
            <div className="space-y-2 mt-4">
              <label className="text-sm font-semibold text-gray-700">Ciclo Anterior (Comparação Opcional)</label>
              <select
                value={sisuPrograms.find(p => p.id === selectedSisuId)?.prev_program_id || ''}
                onChange={(e) => handlePrevCycleChange(selectedSisuId, e.target.value)}
                className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-800 focus:outline-none focus:ring-2 focus:ring-green-500"
              >
                <option value="">-- Sem ciclo anterior (ocultar comparação) --</option>
                {sisuPrograms
                  .filter((p) => p.id !== selectedSisuId && p.is_fully_imported)
                  .map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.title} ({p.cycle_year}.{p.cycle_semester}) - {p.status}
                    </option>
                  ))}
              </select>
              <p className="text-xs text-gray-500">
                O ciclo listado acima deve ter completado toda a importação (is_fully_imported).
              </p>
            </div>
          )}

          {selectedSisuId && (
            <div className="space-y-4 pt-2">
              <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                <div className="flex justify-between items-start mb-1">
                  <div>
                    <span className="text-sm font-semibold text-slate-800">1. Vagas Ofertadas (Termo de Adesão)</span>
                    <p className="text-xs text-slate-500 font-mono mt-1">Tabela: rawsisuvacancies</p>
                  </div>
                  {renderStatusBadge('sisu_vacancies', sisuLogs)}
                </div>
                {renderButton('sisu_vacancies', 'Importar Termo de Adesão (Vagas)', false, selectedSisuId, sisuLogs)}
              </div>

              <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
                <div className="flex justify-between items-start mb-1">
                  <div>
                    <span className="text-sm font-semibold text-slate-800">2. Base Consolidada (Notas de Corte)</span>
                    <p className="text-xs text-slate-500 font-mono mt-1">Tabela: rawsisu</p>
                  </div>
                  {renderStatusBadge('sisu', sisuLogs)}
                </div>
                {renderButton('sisu', 'Importar Base Consolidada', false, selectedSisuId, sisuLogs)}
              </div>
            </div>
          )}
        </div>

        {/* EMEC PIPELINE */}
        <div className="bg-white p-6 rounded-xl border border-gray-200 shadow-sm space-y-6">
          <div className="border-b pb-4">
            <h3 className="text-lg font-bold text-gray-900 flex items-center">
              <Database className="w-5 h-5 mr-2 text-orange-500" />
              Pipeline e-MEC
            </h3>
            <p className="text-xs text-gray-500 mt-1">Enriquecimento e metadados globais.</p>
          </div>

          <div className="space-y-4 pt-2">
            <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
              <div className="flex justify-between items-start mb-1">
                <div>
                  <span className="text-sm font-semibold text-slate-800">Enriquecimento de IES</span>
                  <p className="text-xs text-slate-500 font-mono mt-1">Tabela: rawemec</p>
                </div>
                {renderStatusBadge('emec', globalLogs)}
              </div>
              {renderButton('emec', 'Importar Metadados', false, null, globalLogs)}
            </div>
          </div>
        </div>
      
        {/* SYNC PIPELINE */}
        <div className="bg-white p-6 rounded-xl border border-gray-200 shadow-sm space-y-6">
          <div className="border-b pb-4">
            <h3 className="text-lg font-bold text-gray-900 flex items-center">
              <Database className="w-5 h-5 mr-2 text-slate-600" />
              Sincronização
            </h3>
            <p className="text-xs text-gray-500 mt-1">
              Atualização das views materializadas. Rode ao final das importações.
            </p>
          </div>

          <div className="space-y-4 pt-2">
            <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
              <div className="flex justify-between items-start mb-1">
                <div>
                  <span className="text-sm font-semibold text-slate-800">Oportunidades</span>
                  <p className="text-xs text-slate-500 font-mono mt-1">v_unified_opportunities</p>
                </div>
                {renderStatusBadge('refresh_opportunities', globalLogs)}
              </div>
              {renderButton('refresh_opportunities', 'Atualizar', false, null, globalLogs)}
            </div>

            <div className="p-3 bg-slate-50 border border-slate-100 rounded-lg">
              <div className="flex justify-between items-start mb-1">
                <div>
                  <span className="text-sm font-semibold text-slate-800">Catálogo de Cursos</span>
                  <p className="text-xs text-slate-500 font-mono mt-1">mv_course_catalog</p>
                </div>
                {renderStatusBadge('refresh_catalog', globalLogs)}
              </div>
              {renderButton('refresh_catalog', 'Atualizar', false, null, globalLogs)}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
