// PartnerOpportunities.tsx — Sprint 3.8
// Full CRUD page with Create/Edit dialog and Institution select.

import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  listPartnerOpportunities,
  listPartnerInstitutionsForSelect,
  createPartnerOpportunity,
  updatePartnerOpportunity,
  updatePartnerOpportunityStatus,
  deletePartnerOpportunity,
  type PartnerOpportunity,
  type OpportunityStatus,
  type PartnerOpportunityType,
  type CreatePartnerOpportunityInput,
} from '@/services/partnerOpportunitiesService';
import { toast } from 'sonner';
import { Plus } from 'lucide-react';

const STATUS_LABELS: Record<OpportunityStatus, string> = {
  draft:          'Rascunho',
  pending_review: 'Aguardando Revisão',
  approved:       'Aprovada',
};

const STATUS_COLORS: Record<OpportunityStatus, string> = {
  draft:          'bg-gray-100 text-gray-700',
  pending_review: 'bg-yellow-100 text-yellow-800',
  approved:       'bg-green-100 text-green-800',
};

const TYPE_LABELS: Record<PartnerOpportunityType, string> = {
  bolsa:     'Bolsa',
  bootcamp:  'Bootcamp',
  mentoria:  'Mentoria',
};

interface FormState {
  institution_id: string;
  name: string;
  description: string;
  opportunity_type: PartnerOpportunityType;
  status: OpportunityStatus;
  redirect_url: string;
  redirect_enabled: boolean;
  starts_at: string;
  ends_at: string;
}

const emptyForm: FormState = {
  institution_id: '',
  name: '',
  description: '',
  opportunity_type: 'bolsa',
  status: 'draft',
  redirect_url: '',
  redirect_enabled: false,
  starts_at: '',
  ends_at: '',
};

function getVigenciaBadge(starts_at: string | null, ends_at: string | null) {
  if (!starts_at && !ends_at) return { label: 'Sem prazo', className: 'bg-gray-100 text-gray-600' };
  const now = new Date();
  if (ends_at) {
    const end = new Date(ends_at);
    if (end < now) return { label: 'Encerrado', className: 'bg-red-100 text-red-700' };
    const daysLeft = Math.ceil((end.getTime() - now.getTime()) / (1000 * 60 * 60 * 24));
    if (daysLeft <= 7) return { label: `Encerra em ${daysLeft}d`, className: 'bg-yellow-100 text-yellow-800' };
  }
  const start = starts_at ? new Date(starts_at) : null;
  if (!start || start <= now) return { label: 'Aberto', className: 'bg-green-100 text-green-700' };
  return { label: 'Futuro', className: 'bg-blue-100 text-blue-700' };
}

function formatDatetimeLocal(iso: string): string {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function PartnerOpportunitiesPage() {
  const [page, setPage]           = useState(0);
  const [statusFilter, setStatus] = useState<OpportunityStatus | 'all'>('all');
  const [dialogMode, setDialogMode] = useState<'closed' | 'create' | 'edit'>('closed');
  const [editingId, setEditingId] = useState<string | null>(null);
  const [formState, setFormState] = useState<FormState>(emptyForm);

  const queryClient = useQueryClient();
  const PAGE_SIZE = 20;

  // Fetch list
  const { data, isLoading, isError } = useQuery({
    queryKey: ['partner-opportunities', page, statusFilter],
    queryFn:  () => listPartnerOpportunities({ page, limit: PAGE_SIZE, status: statusFilter }),
  });

  // Fetch institutions for select
  const { data: institutions = [] } = useQuery({
    queryKey: ['partner-institutions-select'],
    queryFn:  listPartnerInstitutionsForSelect,
  });

  // Create mutation
  const createMutation = useMutation({
    mutationFn: (input: CreatePartnerOpportunityInput) => createPartnerOpportunity(input),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['partner-opportunities'] });
      toast.success('Oportunidade criada com sucesso!');
      closeDialog();
    },
    onError: () => toast.error('Erro ao criar oportunidade.'),
  });

  // Update mutation
  const updateMutation = useMutation({
    mutationFn: ({ id, input }: { id: string; input: Partial<CreatePartnerOpportunityInput> }) =>
      updatePartnerOpportunity(id, input),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['partner-opportunities'] });
      toast.success('Oportunidade atualizada com sucesso!');
      closeDialog();
    },
    onError: () => toast.error('Erro ao atualizar oportunidade.'),
  });

  // Status mutation
  const statusMutation = useMutation({
    mutationFn: ({ id, status }: { id: string; status: OpportunityStatus }) =>
      updatePartnerOpportunityStatus(id, status),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['partner-opportunities'] });
    },
  });

  // Delete mutation
  const deleteMutation = useMutation({
    mutationFn: (id: string) => deletePartnerOpportunity(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['partner-opportunities'] });
      toast.success('Oportunidade removida.');
    },
  });

  const openCreate = () => {
    setFormState(emptyForm);
    setEditingId(null);
    setDialogMode('create');
  };

  const openEdit = (opp: PartnerOpportunity) => {
    setFormState({
      institution_id:   opp.institution_id,
      name:             opp.name,
      description:      opp.description ?? '',
      opportunity_type: opp.opportunity_type,
      status:           opp.status,
      redirect_url:     (opp.external_redirect_config as any)?.url ?? '',
      redirect_enabled: (opp.external_redirect_config as any)?.enabled ?? false,
      starts_at:        opp.starts_at ? formatDatetimeLocal(opp.starts_at) : '',
      ends_at:          opp.ends_at ? formatDatetimeLocal(opp.ends_at) : '',
    });
    setEditingId(opp.id);
    setDialogMode('edit');
  };

  const closeDialog = () => {
    setDialogMode('closed');
    setEditingId(null);
    setFormState(emptyForm);
  };

  const handleSave = () => {
    const input: CreatePartnerOpportunityInput = {
      institution_id: formState.institution_id,
      name: formState.name,
      description: formState.description || undefined,
      opportunity_type: formState.opportunity_type,
      external_redirect_config: {
        enabled: formState.redirect_enabled,
        url: formState.redirect_url || undefined,
      },
      starts_at: formState.starts_at ? new Date(formState.starts_at).toISOString() : null,
      ends_at: formState.ends_at ? new Date(formState.ends_at).toISOString() : null,
    };

    if (dialogMode === 'create') {
      createMutation.mutate(input);
    } else if (editingId) {
      updateMutation.mutate({ id: editingId, input });
    }
  };

  const totalPages = data ? Math.ceil(data.count / PAGE_SIZE) : 0;
  const isSaving = createMutation.isPending || updateMutation.isPending;

  return (
    <div className="p-6">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold text-gray-800">Oportunidades Parceiras</h1>
          <span className="text-sm text-gray-500">
            {data?.count ?? 0} oportunidade{data?.count !== 1 ? 's' : ''}
          </span>
        </div>
        <button
          onClick={openCreate}
          className="flex items-center gap-2 px-4 py-2 text-sm font-semibold text-white bg-blue-600 rounded-lg hover:bg-blue-700 transition-colors"
        >
          <Plus className="h-4 w-4" />
          Nova Oportunidade
        </button>
      </div>

      {/* Status filter */}
      <div className="flex gap-2 mb-4 flex-wrap">
        {(['all', 'draft', 'pending_review', 'approved'] as const).map((s) => (
          <button
            key={s}
            onClick={() => { setStatus(s); setPage(0); }}
            className={`px-3 py-1.5 text-sm rounded-full font-medium transition-colors ${
              statusFilter === s
                ? 'bg-blue-600 text-white'
                : 'bg-gray-100 text-gray-600 hover:bg-gray-200'
            }`}
          >
            {s === 'all' ? 'Todas' : STATUS_LABELS[s]}
          </button>
        ))}
      </div>

      {/* Table */}
      {isLoading ? (
        <div className="py-12 text-center text-gray-500">Carregando...</div>
      ) : isError ? (
        <div className="py-12 text-center text-red-500">Erro ao carregar oportunidades.</div>
      ) : (
        <div className="border border-gray-200 rounded-xl overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-gray-50 border-b border-gray-200">
              <tr>
                <th className="text-left px-4 py-3 font-semibold text-gray-600">Nome</th>
                <th className="text-left px-4 py-3 font-semibold text-gray-600">Instituição</th>
                <th className="text-left px-4 py-3 font-semibold text-gray-600">Tipo</th>
                <th className="text-left px-4 py-3 font-semibold text-gray-600">Status</th>
                <th className="text-left px-4 py-3 font-semibold text-gray-600">Vigência</th>
                <th className="text-left px-4 py-3 font-semibold text-gray-600">Criado em</th>
                <th className="text-right px-4 py-3 font-semibold text-gray-600">Ações</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {(data?.data ?? []).length === 0 ? (
                <tr>
                  <td colSpan={7} className="px-4 py-8 text-center text-gray-400">
                    Nenhuma oportunidade encontrada.
                  </td>
                </tr>
              ) : (
                (data?.data ?? []).map((opp) => (
                  <tr key={opp.id} className="hover:bg-gray-50">
                    <td className="px-4 py-3 font-medium text-gray-800 max-w-xs truncate">
                      {opp.name}
                    </td>
                    <td className="px-4 py-3 text-gray-600">
                      {opp.institution_name ?? '—'}
                    </td>
                    <td className="px-4 py-3 text-gray-600">
                      {TYPE_LABELS[opp.opportunity_type]}
                    </td>
                    <td className="px-4 py-3">
                      <span className={`px-2 py-1 rounded-full text-xs font-medium ${STATUS_COLORS[opp.status]}`}>
                        {STATUS_LABELS[opp.status]}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      {(() => {
                        const badge = getVigenciaBadge(opp.starts_at, opp.ends_at);
                        return (
                          <span className={`px-2 py-1 rounded-full text-xs font-medium ${badge.className}`}>
                            {badge.label}
                          </span>
                        );
                      })()}
                    </td>
                    <td className="px-4 py-3 text-gray-500">
                      {new Date(opp.created_at).toLocaleDateString('pt-BR')}
                    </td>
                    <td className="px-4 py-3 text-right">
                      <div className="flex items-center justify-end gap-2">
                        {opp.status !== 'approved' && (
                          <button
                            onClick={() => statusMutation.mutate({ id: opp.id, status: 'approved' })}
                            disabled={statusMutation.isPending}
                            className="px-3 py-1 text-xs font-semibold text-green-700 bg-green-100 rounded-full hover:bg-green-200 transition-colors disabled:opacity-50"
                          >
                            Aprovar
                          </button>
                        )}
                        {opp.status === 'approved' && (
                          <button
                            onClick={() => statusMutation.mutate({ id: opp.id, status: 'draft' })}
                            disabled={statusMutation.isPending}
                            className="px-3 py-1 text-xs font-semibold text-red-700 bg-red-100 rounded-full hover:bg-red-200 transition-colors disabled:opacity-50"
                          >
                            Rejeitar
                          </button>
                        )}
                        <button
                          onClick={() => openEdit(opp)}
                          className="px-3 py-1 text-xs font-semibold text-blue-700 bg-blue-100 rounded-full hover:bg-blue-200 transition-colors"
                        >
                          Editar
                        </button>
                        <button
                          onClick={() => {
                            if (window.confirm(`Deletar "${opp.name}"?`)) {
                              deleteMutation.mutate(opp.id);
                            }
                          }}
                          disabled={deleteMutation.isPending}
                          className="px-3 py-1 text-xs font-semibold text-gray-700 bg-gray-100 rounded-full hover:bg-gray-200 transition-colors disabled:opacity-50"
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
      )}

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between mt-4">
          <button
            onClick={() => setPage(p => Math.max(0, p - 1))}
            disabled={page === 0}
            className="px-4 py-2 text-sm font-semibold text-gray-700 border border-gray-300 rounded-lg hover:bg-gray-50 disabled:opacity-40"
          >
            Anterior
          </button>
          <span className="text-sm text-gray-500">
            Página {page + 1} de {totalPages}
          </span>
          <button
            onClick={() => setPage(p => Math.min(totalPages - 1, p + 1))}
            disabled={page >= totalPages - 1}
            className="px-4 py-2 text-sm font-semibold text-gray-700 border border-gray-300 rounded-lg hover:bg-gray-50 disabled:opacity-40"
          >
            Próxima
          </button>
        </div>
      )}

      {/* Create / Edit Dialog (overlay) */}
      {dialogMode !== 'closed' && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm">
          <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg mx-4 max-h-[90vh] overflow-y-auto">
            <div className="px-6 py-5 border-b">
              <h2 className="text-lg font-bold text-gray-800">
                {dialogMode === 'create' ? 'Nova Oportunidade Parceira' : 'Editar Oportunidade'}
              </h2>
            </div>

            <div className="px-6 py-5 space-y-4">
              {/* Institution select */}
              <div>
                <label className="text-sm font-semibold text-gray-600 block mb-1">Instituição *</label>
                <select
                  value={formState.institution_id}
                  onChange={(e) => setFormState(prev => ({ ...prev, institution_id: e.target.value }))}
                  disabled={dialogMode === 'edit'}
                  className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-gray-100 disabled:cursor-not-allowed"
                >
                  <option value="">Selecione uma instituição...</option>
                  {institutions.map((inst) => (
                    <option key={inst.id} value={inst.id}>{inst.name}</option>
                  ))}
                </select>
              </div>

              {/* Name */}
              <div>
                <label className="text-sm font-semibold text-gray-600 block mb-1">Nome da Oportunidade *</label>
                <input
                  value={formState.name}
                  onChange={(e) => setFormState(prev => ({ ...prev, name: e.target.value }))}
                  placeholder="Ex: Bolsa Integral 2026"
                  className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>

              {/* Description */}
              <div>
                <label className="text-sm font-semibold text-gray-600 block mb-1">Descrição</label>
                <textarea
                  value={formState.description}
                  onChange={(e) => setFormState(prev => ({ ...prev, description: e.target.value }))}
                  rows={3}
                  placeholder="Breve descrição da oportunidade..."
                  className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>

              {/* Type */}
              <div>
                <label className="text-sm font-semibold text-gray-600 block mb-1">Tipo *</label>
                <select
                  value={formState.opportunity_type}
                  onChange={(e) => setFormState(prev => ({ ...prev, opportunity_type: e.target.value as PartnerOpportunityType }))}
                  className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                >
                  <option value="bolsa">Bolsa</option>
                  <option value="bootcamp">Bootcamp</option>
                  <option value="mentoria">Mentoria</option>
                </select>
              </div>

              {/* Dates */}
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="text-sm font-semibold text-gray-600 block mb-1">Início das Inscrições</label>
                  <input
                    type="datetime-local"
                    value={formState.starts_at}
                    onChange={(e) => setFormState(prev => ({ ...prev, starts_at: e.target.value }))}
                    className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  />
                </div>
                <div>
                  <label className="text-sm font-semibold text-gray-600 block mb-1">Fim das Inscrições</label>
                  <input
                    type="datetime-local"
                    value={formState.ends_at}
                    onChange={(e) => setFormState(prev => ({ ...prev, ends_at: e.target.value }))}
                    className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  />
                </div>
              </div>

              {/* External Redirect */}
              <div className="border rounded-lg p-4 space-y-3 bg-gray-50/50">
                <label className="flex items-center gap-2 text-sm font-semibold text-gray-600 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={formState.redirect_enabled}
                    onChange={(e) => setFormState(prev => ({ ...prev, redirect_enabled: e.target.checked }))}
                    className="rounded"
                  />
                  Redirecionamento externo habilitado
                </label>
                {formState.redirect_enabled && (
                  <div>
                    <label className="text-xs font-semibold text-gray-600 block mb-1">URL de Redirect</label>
                    <input
                      value={formState.redirect_url}
                      onChange={(e) => setFormState(prev => ({ ...prev, redirect_url: e.target.value }))}
                      placeholder="https://..."
                      className="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                    />
                  </div>
                )}
              </div>
            </div>

            {/* Dialog footer */}
            <div className="px-6 py-4 border-t flex justify-end gap-3">
              <button
                onClick={closeDialog}
                className="px-4 py-2 text-sm font-semibold text-gray-700 bg-gray-200 rounded-lg hover:bg-gray-300 transition-colors"
              >
                Cancelar
              </button>
              <button
                onClick={handleSave}
                disabled={isSaving || !formState.name || !formState.institution_id}
                className="px-4 py-2 text-sm font-semibold text-white bg-blue-600 rounded-lg hover:bg-blue-700 transition-colors disabled:opacity-50"
              >
                {isSaving ? 'Salvando...' : dialogMode === 'create' ? 'Criar Oportunidade' : 'Salvar Alterações'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
