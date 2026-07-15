import React, { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { 
    getOpportunityPhases, 
    createOpportunityPhase, 
    deleteOpportunityPhase, 
    reorderOpportunityPhases 
} from "@/services/applicationsService";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogDescription,
    DialogTrigger,
    DialogFooter
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Loader2, Plus, GripVertical, Trash2, GitMerge } from "lucide-react";
import { toast } from "sonner";
import {
    DndContext,
    closestCenter,
    KeyboardSensor,
    PointerSensor,
    useSensor,
    useSensors,
    DragEndEvent,
} from '@dnd-kit/core';
import {
    arrayMove,
    SortableContext,
    sortableKeyboardCoordinates,
    verticalListSortingStrategy,
    useSortable
} from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';

interface PhaseManagerModalProps {
    opportunityId: string;
    opportunityName: string;
    trigger?: React.ReactNode;
}

// Sortable Item Component
function SortablePhaseItem({ phase, onDeleteClick }: { phase: any, onDeleteClick: (phase: any) => void }) {
    const {
        attributes,
        listeners,
        setNodeRef,
        transform,
        transition,
    } = useSortable({ id: phase.id });

    const style = {
        transform: CSS.Transform.toString(transform),
        transition,
    };

    return (
        <div 
            ref={setNodeRef} 
            style={style} 
            className="flex items-center justify-between p-3 mb-2 bg-white border rounded-md shadow-sm"
        >
            <div className="flex items-center gap-3">
                <div {...attributes} {...listeners} className="cursor-grab hover:bg-slate-100 p-1 rounded">
                    <GripVertical className="h-5 w-5 text-slate-400" />
                </div>
                <div>
                    <span className="font-medium">{phase.name}</span>
                </div>
            </div>
            <Button variant="ghost" size="icon" onClick={() => onDeleteClick(phase)} className="text-red-500 hover:text-red-700 hover:bg-red-50">
                <Trash2 className="h-4 w-4" />
            </Button>
        </div>
    );
}


export function PhaseManagerModal({ opportunityId, opportunityName, trigger }: PhaseManagerModalProps) {
    const queryClient = useQueryClient();
    const [isOpen, setIsOpen] = useState(false);
    
    const [newPhaseName, setNewPhaseName] = useState("");
    
    // Deletion state
    const [phaseToDelete, setPhaseToDelete] = useState<any | null>(null);
    const [fallbackPhaseId, setFallbackPhaseId] = useState<string>("none");

    const sensors = useSensors(
        useSensor(PointerSensor),
        useSensor(KeyboardSensor, {
            coordinateGetter: sortableKeyboardCoordinates,
        })
    );

    // Fetch Phases
    const { data: phases = [], isLoading } = useQuery({
        queryKey: ["opportunity-phases", opportunityId],
        queryFn: () => getOpportunityPhases(opportunityId),
        enabled: isOpen
    });

    // Create Phase Mutation
    const createMutation = useMutation({
        mutationFn: async (name: string) => {
            // New phase goes at the end
            const maxOrder = phases.length > 0 ? Math.max(...phases.map(p => p.sort_order)) : -1;
            return createOpportunityPhase(opportunityId, name, maxOrder + 1);
        },
        onSuccess: () => {
            toast.success("Fase criada com sucesso");
            setNewPhaseName("");
            queryClient.invalidateQueries({ queryKey: ["opportunity-phases", opportunityId] });
        },
        onError: (err: any) => {
            toast.error("Erro ao criar fase: " + err.message);
        }
    });

    // Delete Phase Mutation
    const deleteMutation = useMutation({
        mutationFn: async ({ id, fallbackId }: { id: string, fallbackId: string | null }) => {
            return deleteOpportunityPhase(id, fallbackId);
        },
        onSuccess: () => {
            toast.success("Fase excluída com sucesso");
            setPhaseToDelete(null);
            setFallbackPhaseId("none");
            queryClient.invalidateQueries({ queryKey: ["opportunity-phases", opportunityId] });
        },
        onError: (err: any) => {
            // Check if it's a constraint violation
            if (err.message?.includes("student_applications_phase_id_fkey") || err.code === '23503') {
                toast.error("Não é possível excluir a fase. Existem candidatos nela. Selecione uma fase de destino para transferi-los.");
            } else {
                toast.error("Erro ao excluir fase: " + err.message);
            }
        }
    });

    // Reorder Mutation
    const reorderMutation = useMutation({
        mutationFn: async (orderedIds: string[]) => {
            return reorderOpportunityPhases(orderedIds);
        },
        onSuccess: () => {
            toast.success("Ordem das fases atualizada");
            queryClient.invalidateQueries({ queryKey: ["opportunity-phases", opportunityId] });
        },
        onError: (err: any) => {
            toast.error("Erro ao reordenar fases: " + err.message);
        }
    });

    const handleCreatePhase = (e: React.FormEvent) => {
        e.preventDefault();
        if (!newPhaseName.trim()) return;
        createMutation.mutate(newPhaseName.trim());
    };

    const handleDragEnd = (event: DragEndEvent) => {
        const { active, over } = event;

        if (over && active.id !== over.id) {
            const oldIndex = phases.findIndex((p) => p.id === active.id);
            const newIndex = phases.findIndex((p) => p.id === over.id);

            const newOrder = arrayMove(phases, oldIndex, newIndex);
            
            // Optimistic update
            queryClient.setQueryData(["opportunity-phases", opportunityId], newOrder);
            
            // Execute mutation to save order
            reorderMutation.mutate(newOrder.map(p => p.id));
        }
    };

    const handleDeleteConfirm = () => {
        if (!phaseToDelete) return;
        const targetFallback = fallbackPhaseId === "none" ? null : fallbackPhaseId;
        deleteMutation.mutate({ id: phaseToDelete.id, fallbackId: targetFallback });
    };

    const remainingPhases = phases.filter(p => p.id !== phaseToDelete?.id);

    return (
        <Dialog open={isOpen} onOpenChange={setIsOpen}>
            <DialogTrigger asChild>
                {trigger || <Button variant="outline"><GitMerge className="mr-2 h-4 w-4" /> Gerenciar Fases</Button>}
            </DialogTrigger>
            <DialogContent className="max-w-md">
                <DialogHeader>
                    <DialogTitle>Gerenciar Fases do Processo</DialogTitle>
                    <DialogDescription>
                        Crie e ordene o funil de recrutamento para a oportunidade <strong>{opportunityName}</strong>.
                    </DialogDescription>
                </DialogHeader>

                <div className="space-y-6 py-4">
                    {/* Add new phase form */}
                    <form onSubmit={handleCreatePhase} className="flex gap-2 items-end">
                        <div className="flex-1 space-y-1">
                            <Label htmlFor="phaseName">Nova Fase</Label>
                            <Input 
                                id="phaseName" 
                                placeholder="Ex: Entrevista Técnica" 
                                value={newPhaseName}
                                onChange={(e) => setNewPhaseName(e.target.value)}
                                disabled={createMutation.isPending}
                            />
                        </div>
                        <Button type="submit" disabled={!newPhaseName.trim() || createMutation.isPending}>
                            {createMutation.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
                        </Button>
                    </form>

                    {/* Draggable Phase List */}
                    <div className="bg-slate-50 p-4 rounded-lg min-h-[150px]">
                        <Label className="mb-3 block text-slate-500">Sequência do Funil</Label>
                        
                        {isLoading ? (
                            <div className="flex justify-center p-4"><Loader2 className="h-6 w-6 animate-spin text-slate-400" /></div>
                        ) : phases.length === 0 ? (
                            <div className="text-center text-slate-400 text-sm py-4">Nenhuma fase configurada.</div>
                        ) : (
                            <DndContext 
                                sensors={sensors}
                                collisionDetection={closestCenter}
                                onDragEnd={handleDragEnd}
                            >
                                <SortableContext 
                                    items={phases.map(p => p.id)}
                                    strategy={verticalListSortingStrategy}
                                >
                                    <div className="space-y-1">
                                        {phases.map((phase) => (
                                            <SortablePhaseItem 
                                                key={phase.id} 
                                                phase={phase} 
                                                onDeleteClick={setPhaseToDelete} 
                                            />
                                        ))}
                                    </div>
                                </SortableContext>
                            </DndContext>
                        )}
                    </div>
                </div>

            </DialogContent>

            {/* Deletion Fallback Sub-modal */}
            <Dialog open={!!phaseToDelete} onOpenChange={(open) => !open && setPhaseToDelete(null)}>
                <DialogContent className="max-w-sm">
                    <DialogHeader>
                        <DialogTitle>Excluir Fase</DialogTitle>
                        <DialogDescription>
                            Você está prestes a excluir a fase <strong>{phaseToDelete?.name}</strong>.
                        </DialogDescription>
                    </DialogHeader>
                    
                    <div className="py-4 space-y-3">
                        <p className="text-sm text-slate-600">
                            Se houver candidatos nesta fase, eles perderão o status. Para evitar isso, escolha para qual fase deseja transferi-los:
                        </p>
                        <Select value={fallbackPhaseId} onValueChange={setFallbackPhaseId}>
                            <SelectTrigger>
                                <SelectValue placeholder="Selecione uma fase de destino" />
                            </SelectTrigger>
                            <SelectContent>
                                <SelectItem value="none">Nenhuma fase (Deixar em branco)</SelectItem>
                                {remainingPhases.map(p => (
                                    <SelectItem key={p.id} value={p.id}>{p.name}</SelectItem>
                                ))}
                            </SelectContent>
                        </Select>
                    </div>

                    <DialogFooter>
                        <Button variant="outline" onClick={() => setPhaseToDelete(null)}>Cancelar</Button>
                        <Button 
                            variant="destructive" 
                            onClick={handleDeleteConfirm}
                            disabled={deleteMutation.isPending}
                        >
                            {deleteMutation.isPending ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : "Confirmar Exclusão"}
                        </Button>
                    </DialogFooter>
                </DialogContent>
            </Dialog>

        </Dialog>
    );
}
