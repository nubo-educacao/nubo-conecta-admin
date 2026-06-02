import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  listPrograms,
  createProgram,
  updateProgram,
  updateProgramStatus,
  deleteProgram,
  type Program,
  type ProgramType,
  type ProgramStatus,
  type CreateProgramInput,
} from '@/services/programsService';
import { toast } from 'sonner';
import { Plus, Calendar, Link as LinkIcon, AlertCircle } from 'lucide-react';

const STATUS_LABELS: Record<ProgramStatus, string> = {
  incoming: 'Em breve',
  opened: 'Aberto',
  closed: 'Encerrado',
};

const STATUS_COLORS: Record<ProgramStatus, string> = {
  incoming: 'bg-yellow-100 text-yellow-800 border-yellow-200',
  opened: 'bg-green-100 text-green-800 border-green-200',
  closed: 'bg-gray-100 text-gray-800 border-gray-200',
};

const TYPE_LABELS: Record<ProgramType, string> = {
  sisu: 'SiSU',
  prouni: 'ProUni',
};

interface FormState {
  type: ProgramType;
  cycle_year: number;
  cycle_semester: string;
  title: string;
  description: string;
  status: ProgramStatus;
  redirect_url: string;
  starts_at: string;
  ends_at: string;
}

const emptyForm: FormState = {
  type: 'sisu',
  cycle_year: new Date().getFullYear(),
  cycle_semester: '1',
  title: '',
  description: '',
  status: 'incoming',
  redirect_url: '',
  starts_at: '',
  ends_at: '',
};

function formatDatetimeLocal(iso: string): string {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function ProgramsPage() {
  const [typeFilter, setTypeFilter] = useState<ProgramType | 'all'>('all');
  const [statusFilter, setStatusFilter] = useState<ProgramStatus | 'all'>('all');
  const [dialogMode, setDialogMode] = useState<'closed' | 'create' | 'edit'>('closed');
  const [editingId, setEditingId] = useState<string | null>(null);
  const [formState, setFormState] = useState<FormState>(emptyForm);
  const [previewDescription, setPreviewDescription] = useState(false);

  const queryClient = useQueryClient();

  // Fetch list
  const { data: programs = [], isLoading, isError } = useQuery({
    queryKey: ['programs', typeFilter, statusFilter],
    queryFn: () => listPrograms({ 
      type: typeFilter, 
      status: statusFilter 
    }),
  });

  // Create mutation
  const createMutation = useMutation({
    mutationFn: (input: CreateProgramInput) => createProgram(input),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['programs'] });
      toast.success('Programa criado com sucesso!');
      closeDialog();
    },
    onError: (err: any) => {
      toast.error(`Erro ao criar programa: ${err.message || err}`);
    },
  });

  // Update mutation
  const updateMutation = useMutation({
    mutationFn: ({ id, input }: { id: string; input: Partial<CreateProgramInput> }) =>
      updateProgram(id, input),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['programs'] });
      toast.success('Programa atualizado com sucesso!');
      closeDialog();
    },
    onError: (err: any) => {
      toast.error(`Erro ao atualizar programa: ${err.message || err}`);
    },
  });

  // Status transition mutation
  const statusMutation = useMutation({
    mutationFn: ({ id, status }: { id: string; status: ProgramStatus }) =>
      updateProgramStatus(id, status),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['programs'] });
      toast.success('Status atualizado!');
    },
    onError: (err: any) => {
      toast.error(`Erro ao atualizar status: ${err.message || err}`);
    },
  });

  // Delete mutation
  const deleteMutation = useMutation({
    mutationFn: (id: string) => deleteProgram(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['programs'] });
      toast.success('Programa removido com sucesso.');
    },
    onError: (err: any) => {
      toast.error(`Erro ao excluir programa: ${err.message || err}`);
    },
  });

  const openCreate = () => {
    setFormState({
      ...emptyForm,
      cycle_year: new Date().getFullYear(),
    });
    setEditingId(null);
    setDialogMode('create');
    setPreviewDescription(false);
  };

  const openEdit = (prog: Program) => {
    setFormState({
      type: prog.type,
      cycle_year: prog.cycle_year,
      cycle_semester: prog.cycle_semester,
      title: prog.title,
      description: prog.description ?? '',
      status: prog.status,
      redirect_url: prog.redirect_url ?? '',
      starts_at: prog.starts_at ? formatDatetimeLocal(prog.starts_at) : '',
      ends_at: prog.ends_at ? formatDatetimeLocal(prog.ends_at) : '',
    });
    setEditingId(prog.id);
    setDialogMode('edit');
    setPreviewDescription(false);
  };

  const closeDialog = () => {
    setDialogMode('closed');
    setEditingId(null);
    setFormState(emptyForm);
  };

  const handleSave = () => {
    const input: CreateProgramInput = {
      type: formState.type,
      cycle_year: Number(formState.cycle_year),
      cycle_semester: formState.cycle_semester,
      title: formState.title,
      description: formState.description || null,
      status: formState.status,
      redirect_url: formState.redirect_url || null,
      starts_at: formState.starts_at ? new Date(formState.starts_at).toISOString() : null,
      ends_at: formState.ends_at ? new Date(formState.ends_at).toISOString() : null,
    };

    if (dialogMode === 'create') {
      createMutation.mutate(input);
    } else if (editingId) {
      updateMutation.mutate({ id: editingId, input });
    }
  };

  const isSaving = createMutation.isPending || updateMutation.isPending;

  return (
    <div className="p-6 max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-3xl font-extrabold text-slate-900 tracking-tight">Programas MEC</h1>
          <p className="text-sm text-slate-500 mt-1">
            Gerenciamento do ciclo de vida e conteúdos dinâmicos do SiSU e ProUni.
          </p>
        </div>
        <button
          onClick={openCreate}
          className="flex items-center justify-center gap-2 px-4 py-2.5 text-sm font-semibold text-white bg-blue-600 rounded-xl hover:bg-blue-700 transition-all duration-200 shadow-sm shadow-blue-100 hover:shadow-blue-200 hover:-translate-y-0.5 active:translate-y-0"
        >
          <Plus className="h-4 w-4" />
          Novo Programa
        </button>
      </div>

      {/* Filters Card */}
      <div className="bg-white/80 backdrop-blur-md border border-slate-100 rounded-2xl p-4 shadow-sm flex flex-wrap gap-4 items-center justify-between">
        <div className="flex flex-wrap gap-3">
          {/* Type Filter */}
          <div className="flex rounded-lg border border-slate-200 p-0.5 bg-slate-50">
            {(['all', 'sisu', 'prouni'] as const).map((t) => (
              <button
                key={t}
                onClick={() => setTypeFilter(t)}
                className={`px-3 py-1.5 text-xs font-semibold rounded-md transition-all duration-150 ${
                  typeFilter === t
                    ? 'bg-white text-slate-900 shadow-sm'
                    : 'text-slate-500 hover:text-slate-800'
                }`}
              >
                {t === 'all' ? 'Todos os Tipos' : TYPE_LABELS[t]}
              </button>
            ))}
          </div>

          {/* Status Filter */}
          <div className="flex rounded-lg border border-slate-200 p-0.5 bg-slate-50">
            {(['all', 'incoming', 'opened', 'closed'] as const).map((s) => (
              <button
                key={s}
                onClick={() => setStatusFilter(s)}
                className={`px-3 py-1.5 text-xs font-semibold rounded-md transition-all duration-150 ${
                  statusFilter === s
                    ? 'bg-white text-slate-900 shadow-sm'
                    : 'text-slate-500 hover:text-slate-800'
                }`}
              >
                {s === 'all' ? 'Todos os Status' : STATUS_LABELS[s]}
              </button>
            ))}
          </div>
        </div>

        <span className="text-xs font-medium text-slate-400">
          {programs.length} {programs.length !== 1 ? 'programas' : 'programa'}{' '}
          {typeFilter !== 'all' || statusFilter !== 'all'
            ? programs.length !== 1 ? 'encontrados' : 'encontrado'
            : programs.length !== 1 ? 'cadastrados' : 'cadastrado'}
        </span>
      </div>

      {/* Table */}
      {isLoading ? (
        <div className="flex flex-col items-center justify-center py-20 space-y-3">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
          <span className="text-sm text-slate-500 font-medium">Carregando programas...</span>
        </div>
      ) : isError ? (
        <div className="flex flex-col items-center justify-center py-20 text-center space-y-2 max-w-md mx-auto">
          <AlertCircle className="h-10 w-10 text-red-500" />
          <h3 className="font-bold text-slate-800 text-lg">Falha ao carregar programas</h3>
          <p className="text-sm text-slate-500">
            Houve um erro ao recuperar os dados do servidor. Por favor, recarregue a página ou tente novamente mais tarde.
          </p>
        </div>
      ) : (
        <div className="bg-white border border-slate-100 rounded-2xl shadow-sm overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm text-left">
              <thead className="bg-slate-50/70 border-b border-slate-100 text-slate-500 font-semibold text-xs tracking-wider uppercase">
                <tr>
                  <th className="px-6 py-4">Título</th>
                  <th className="px-6 py-4">Tipo</th>
                  <th className="px-6 py-4">Ciclo</th>
                  <th className="px-6 py-4">Status</th>
                  <th className="px-6 py-4">Período de Inscrição</th>
                  <th className="px-6 py-4 text-right">Ações</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 text-slate-700">
                {programs.length === 0 ? (
                  <tr>
                    <td colSpan={6} className="px-6 py-16 text-center text-slate-400 font-medium">
                      Nenhum programa MEC cadastrado ou correspondente aos filtros.
                    </td>
                  </tr>
                ) : (
                  programs.map((prog) => (
                    <tr key={prog.id} className="hover:bg-slate-50/40 transition-colors group">
                      <td className="px-6 py-4 font-bold text-slate-900">
                        <div>
                          <span>{prog.title}</span>
                          {prog.redirect_url && (
                            <a
                              href={prog.redirect_url}
                              target="_blank"
                              rel="noreferrer"
                              className="inline-flex ml-2 text-slate-400 hover:text-blue-500 transition-colors align-middle"
                              title={prog.redirect_url}
                            >
                              <LinkIcon className="h-3.5 w-3.5" />
                            </a>
                          )}
                        </div>
                        {prog.description && (
                          <span className="text-xs font-normal text-slate-400 line-clamp-1 mt-0.5 max-w-sm">
                            {prog.description}
                          </span>
                        )}
                      </td>
                      <td className="px-6 py-4">
                        <span className={`inline-flex px-2 py-0.5 rounded-md text-xs font-bold ${
                          prog.type === 'sisu' ? 'bg-indigo-50 text-indigo-700 border border-indigo-100' : 'bg-cyan-50 text-cyan-700 border border-cyan-100'
                        }`}>
                          {TYPE_LABELS[prog.type]}
                        </span>
                      </td>
                      <td className="px-6 py-4 font-medium text-slate-600">
                        {prog.cycle_year}.{prog.cycle_semester}
                      </td>
                      <td className="px-6 py-4">
                        <span className={`inline-flex px-2.5 py-0.5 rounded-full text-xs font-semibold border ${STATUS_COLORS[prog.status]}`}>
                          {STATUS_LABELS[prog.status]}
                        </span>
                      </td>
                      <td className="px-6 py-4 text-xs text-slate-500 font-medium">
                        {prog.starts_at || prog.ends_at ? (
                          <div className="flex items-center gap-1.5">
                            <Calendar className="h-3.5 w-3.5 text-slate-400" />
                            <span>
                              {prog.starts_at ? new Date(prog.starts_at).toLocaleDateString('pt-BR') : '—'} 
                              {' até '} 
                              {prog.ends_at ? new Date(prog.ends_at).toLocaleDateString('pt-BR') : '—'}
                            </span>
                          </div>
                        ) : (
                          <span className="text-slate-400 italic">Não configuradas</span>
                        )}
                      </td>
                      <td className="px-6 py-4 text-right">
                        <div className="flex items-center justify-end gap-2 opacity-90 group-hover:opacity-100 transition-opacity">
                          {/* Toggle Transitions */}
                          {prog.status === 'incoming' && (
                            <button
                              onClick={() => statusMutation.mutate({ id: prog.id, status: 'opened' })}
                              disabled={statusMutation.isPending}
                              className="px-2.5 py-1 text-xs font-bold text-green-700 bg-green-50 hover:bg-green-100 rounded-lg transition-colors border border-green-200/50 disabled:opacity-50"
                            >
                              Abrir Inscrições
                            </button>
                          )}
                          {prog.status === 'opened' && (
                            <button
                              onClick={() => statusMutation.mutate({ id: prog.id, status: 'closed' })}
                              disabled={statusMutation.isPending}
                              className="px-2.5 py-1 text-xs font-bold text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-lg transition-colors border border-slate-200/50 disabled:opacity-50"
                            >
                              Encerrar
                            </button>
                          )}
                          {prog.status === 'closed' && (
                            <button
                              onClick={() => statusMutation.mutate({ id: prog.id, status: 'incoming' })}
                              disabled={statusMutation.isPending}
                              className="px-2.5 py-1 text-xs font-bold text-yellow-700 bg-yellow-50 hover:bg-yellow-100 rounded-lg transition-colors border border-yellow-200/50 disabled:opacity-50"
                            >
                              Tornar Breve
                            </button>
                          )}

                          <button
                            onClick={() => openEdit(prog)}
                            className="px-2.5 py-1 text-xs font-bold text-blue-700 bg-blue-50 hover:bg-blue-100 rounded-lg transition-colors border border-blue-200/50"
                          >
                            Editar
                          </button>
                          
                          <button
                            onClick={() => {
                              if (window.confirm(`Deseja realmente remover o programa "${prog.title}"? Esta ação não pode ser desfeita.`)) {
                                deleteMutation.mutate(prog.id);
                              }
                            }}
                            disabled={deleteMutation.isPending}
                            className="px-2.5 py-1 text-xs font-bold text-red-700 bg-red-50 hover:bg-red-100 rounded-lg transition-colors border border-red-200/50 disabled:opacity-50"
                          >
                            Excluir
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Dialog Overlay */}
      {dialogMode !== 'closed' && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/60 backdrop-blur-md transition-all duration-300">
          <div className="bg-white rounded-3xl shadow-2xl w-full max-w-xl mx-4 max-h-[92vh] flex flex-col border border-slate-100 overflow-hidden animate-in fade-in-50 zoom-in-95 duration-200">
            {/* Dialog Header */}
            <div className="px-6 py-5 border-b border-slate-100 flex items-center justify-between">
              <h2 className="text-xl font-extrabold text-slate-800">
                {dialogMode === 'create' ? 'Novo Programa MEC' : 'Editar Programa MEC'}
              </h2>
              <button 
                onClick={closeDialog}
                className="text-slate-400 hover:text-slate-600 p-1.5 hover:bg-slate-50 rounded-lg transition-colors text-sm font-semibold"
              >
                ✕
              </button>
            </div>

            {/* Dialog Body */}
            <div className="p-6 space-y-4 overflow-y-auto flex-1">
              <div className="grid grid-cols-2 gap-4">
                {/* Type */}
                <div>
                  <label className="text-xs font-bold text-slate-500 uppercase block mb-1.5">Tipo *</label>
                  <select
                    value={formState.type}
                    onChange={(e) => setFormState(prev => ({ ...prev, type: e.target.value as ProgramType }))}
                    className="w-full border border-slate-200 bg-slate-50/50 rounded-xl px-3 py-2.5 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-blue-500/20 focus:border-blue-500 transition-all"
                  >
                    <option value="sisu">SiSU</option>
                    <option value="prouni">ProUni</option>
                  </select>
                </div>

                {/* Status */}
                <div>
                  <label className="text-xs font-bold text-slate-500 uppercase block mb-1.5">Status Inicial *</label>
                  <select
                    value={formState.status}
                    onChange={(e) => setFormState(prev => ({ ...prev, status: e.target.value as ProgramStatus }))}
                    className="w-full border border-slate-200 bg-slate-50/50 rounded-xl px-3 py-2.5 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-blue-500/20 focus:border-blue-500 transition-all"
                  >
                    <option value="incoming">Em breve</option>
                    <option value="opened">Aberto</option>
                    <option value="closed">Encerrado</option>
                  </select>
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                {/* Cycle Year */}
                <div>
                  <label className="text-xs font-bold text-slate-500 uppercase block mb-1.5">Ano do Ciclo *</label>
                  <input
                    type="number"
                    value={formState.cycle_year}
                    onChange={(e) => setFormState(prev => ({ ...prev, cycle_year: Number(e.target.value) }))}
                    placeholder="Ex: 2026"
                    className="w-full border border-slate-200 bg-slate-50/50 rounded-xl px-3 py-2.5 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-blue-500/20 focus:border-blue-500 transition-all"
                  />
                </div>

                {/* Cycle Semester */}
                <div>
                  <label className="text-xs font-bold text-slate-500 uppercase block mb-1.5">Semestre do Ciclo *</label>
                  <select
                    value={formState.cycle_semester}
                    onChange={(e) => setFormState(prev => ({ ...prev, cycle_semester: e.target.value }))}
                    className="w-full border border-slate-200 bg-slate-50/50 rounded-xl px-3 py-2.5 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-blue-500/20 focus:border-blue-500 transition-all"
                  >
                    <option value="1">1º Semestre</option>
                    <option value="2">2º Semestre</option>
                  </select>
                </div>
              </div>

              {/* Title */}
              <div>
                <label className="text-xs font-bold text-slate-500 uppercase block mb-1.5">Título do Programa *</label>
                <input
                  value={formState.title}
                  onChange={(e) => setFormState(prev => ({ ...prev, title: e.target.value }))}
                  placeholder="Ex: SiSU 2026.1"
                  className="w-full border border-slate-200 bg-slate-50/50 rounded-xl px-3 py-2.5 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-blue-500/20 focus:border-blue-500 transition-all"
                />
              </div>

              {/* Redirect URL */}
              <div>
                <label className="text-xs font-bold text-slate-500 uppercase block mb-1.5">URL do Portal Oficial (Redirect)</label>
                <input
                  value={formState.redirect_url}
                  onChange={(e) => setFormState(prev => ({ ...prev, redirect_url: e.target.value }))}
                  placeholder="https://sisu.mec.gov.br"
                  className="w-full border border-slate-200 bg-slate-50/50 rounded-xl px-3 py-2.5 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-blue-500/20 focus:border-blue-500 transition-all"
                />
              </div>

              {/* Dates */}
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="text-xs font-bold text-slate-500 uppercase block mb-1.5">Abertura das Inscrições</label>
                  <input
                    type="datetime-local"
                    value={formState.starts_at}
                    onChange={(e) => setFormState(prev => ({ ...prev, starts_at: e.target.value }))}
                    className="w-full border border-slate-200 bg-slate-50/50 rounded-xl px-3 py-2.5 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-blue-500/20 focus:border-blue-500 transition-all"
                  />
                </div>
                <div>
                  <label className="text-xs font-bold text-slate-500 uppercase block mb-1.5">Encerramento das Inscrições</label>
                  <input
                    type="datetime-local"
                    value={formState.ends_at}
                    onChange={(e) => setFormState(prev => ({ ...prev, ends_at: e.target.value }))}
                    className="w-full border border-slate-200 bg-slate-50/50 rounded-xl px-3 py-2.5 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-blue-500/20 focus:border-blue-500 transition-all"
                  />
                </div>
              </div>

              {/* Description */}
              <div className="space-y-1">
                <div className="flex items-center justify-between">
                  <label className="text-xs font-bold text-slate-500 uppercase block">Descrição / Conteúdo Estático (Markdown)</label>
                  <button
                    type="button"
                    onClick={() => setPreviewDescription(!previewDescription)}
                    className="text-xs text-blue-600 hover:text-blue-700 font-semibold"
                  >
                    {previewDescription ? 'Editar Texto' : 'Visualizar Preview'}
                  </button>
                </div>
                {previewDescription ? (
                  <div className="w-full border border-slate-200 rounded-xl px-4 py-3 text-sm bg-slate-50 min-h-[120px] max-h-[200px] overflow-y-auto prose prose-slate">
                    {formState.description ? (
                      <p className="whitespace-pre-line">{formState.description}</p>
                    ) : (
                      <span className="text-slate-400 italic">Sem conteúdo na descrição.</span>
                    )}
                  </div>
                ) : (
                  <textarea
                    value={formState.description}
                    onChange={(e) => setFormState(prev => ({ ...prev, description: e.target.value }))}
                    rows={4}
                    placeholder="O SiSU (Sistema de Seleção Unificada) utiliza a nota do ENEM..."
                    className="w-full border border-slate-200 bg-slate-50/50 rounded-xl px-3 py-2.5 text-sm font-medium focus:outline-none focus:ring-2 focus:ring-blue-500/20 focus:border-blue-500 transition-all"
                  />
                )}
              </div>
            </div>

            {/* Dialog Footer */}
            <div className="px-6 py-4 border-t border-slate-100 flex justify-end gap-3 bg-slate-50/50">
              <button
                onClick={closeDialog}
                className="px-4 py-2.5 text-sm font-semibold text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-xl transition-colors border border-slate-200/40"
              >
                Cancelar
              </button>
              <button
                onClick={handleSave}
                disabled={isSaving || !formState.title || !formState.cycle_year}
                className="px-5 py-2.5 text-sm font-semibold text-white bg-blue-600 rounded-xl hover:bg-blue-700 transition-all duration-150 disabled:opacity-50 disabled:pointer-events-none shadow-sm shadow-blue-100"
              >
                {isSaving ? 'Salvando...' : dialogMode === 'create' ? 'Criar Programa' : 'Salvar Alterações'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
