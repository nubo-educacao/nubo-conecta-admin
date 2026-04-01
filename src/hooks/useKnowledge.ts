import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
    getKnowledgeCategories,
    createKnowledgeCategory,
    updateKnowledgeCategory,
    deleteKnowledgeCategory,
    getKnowledgeDocuments,
    manageKnowledgeDocument,
    getDocumentVersions,
    uploadDocumentContent,
    downloadDocumentContent,
} from "@/services/knowledgeService";

// ============================================================
// Categories
// ============================================================

export function useKnowledgeCategories() {
    return useQuery({
        queryKey: ["knowledge-categories"],
        queryFn: getKnowledgeCategories,
    });
}

export function useCreateKnowledgeCategory() {
    const queryClient = useQueryClient();

    return useMutation({
        mutationFn: createKnowledgeCategory,
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["knowledge-categories"] });
            toast.success("Categoria criada com sucesso!");
        },
        onError: (error: Error) => {
            toast.error(`Erro ao criar categoria: ${error.message}`);
        },
    });
}

export function useUpdateKnowledgeCategory() {
    const queryClient = useQueryClient();

    return useMutation({
        mutationFn: ({ id, ...params }: { id: string; name?: string; label?: string }) =>
            updateKnowledgeCategory(id, params),
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["knowledge-categories"] });
            queryClient.invalidateQueries({ queryKey: ["knowledge-documents"] });
            toast.success("Categoria atualizada!");
        },
        onError: (error: Error) => {
            toast.error(`Erro ao atualizar categoria: ${error.message}`);
        },
    });
}

export function useDeleteKnowledgeCategory() {
    const queryClient = useQueryClient();

    return useMutation({
        mutationFn: deleteKnowledgeCategory,
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["knowledge-categories"] });
            toast.success("Categoria removida!");
        },
        onError: (error: Error) => {
            toast.error(`Erro ao remover categoria: ${error.message}`);
        },
    });
}

// ============================================================
// Documents
// ============================================================

export function useKnowledgeDocuments(filters?: {
    category_id?: string;
    partner_id?: string;
    is_active?: boolean;
}) {
    return useQuery({
        queryKey: ["knowledge-documents", filters],
        queryFn: () => getKnowledgeDocuments(filters),
    });
}

export function useManageKnowledgeDocument() {
    const queryClient = useQueryClient();

    return useMutation({
        mutationFn: manageKnowledgeDocument,
        onSuccess: (data) => {
            queryClient.invalidateQueries({ queryKey: ["knowledge-documents"] });
            const actionLabel =
                data.action === "created" ? "criado" :
                data.action === "updated" ? "atualizado" :
                data.action === "deleted" ? "removido" : data.action;
            toast.success(`Documento ${actionLabel} com sucesso!`);
        },
        onError: (error: Error) => {
            toast.error(`Erro ao gerenciar documento: ${error.message}`);
        },
    });
}

// ============================================================
// Versions
// ============================================================

export function useDocumentVersions(documentId: string | null) {
    return useQuery({
        queryKey: ["knowledge-versions", documentId],
        queryFn: () => getDocumentVersions(documentId!),
        enabled: !!documentId,
    });
}

// ============================================================
// Storage
// ============================================================

export function useUploadDocumentContent() {
    return useMutation({
        mutationFn: ({ storagePath, content }: { storagePath: string; content: string }) =>
            uploadDocumentContent(storagePath, content),
        onError: (error: Error) => {
            toast.error(`Erro ao enviar conteúdo: ${error.message}`);
        },
    });
}

export function useDownloadDocumentContent() {
    return useMutation({
        mutationFn: downloadDocumentContent,
    });
}
