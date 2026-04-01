import React, { useState } from "react";
import { Button } from "@/components/ui/button";
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import { Plus, Settings } from "lucide-react";
import KnowledgeTable from "@/components/knowledge/KnowledgeTable";
import KnowledgeDocumentDialog from "@/components/knowledge/KnowledgeDocumentDialog";
import KnowledgeCategoryManager from "@/components/knowledge/KnowledgeCategoryManager";
import KnowledgeVersionHistory from "@/components/knowledge/KnowledgeVersionHistory";
import {
    useKnowledgeDocuments,
    useKnowledgeCategories,
    useManageKnowledgeDocument,
    useCreateKnowledgeCategory,
    useUpdateKnowledgeCategory,
    useDeleteKnowledgeCategory,
    useDocumentVersions,
    useUploadDocumentContent,
    useDownloadDocumentContent,
} from "@/hooks/useKnowledge";
import type { KnowledgeDocument, KnowledgeDocumentVersion } from "@/services/knowledgeService";
import { supabase } from "@/integrations/supabase/client";
import { useQuery } from "@tanstack/react-query";
import { toast } from "sonner";

export default function KnowledgeBase() {
    // Filters
    const [filterCategoryId, setFilterCategoryId] = useState<string | undefined>(undefined);

    // Dialog state
    const [docDialogOpen, setDocDialogOpen] = useState(false);
    const [editingDoc, setEditingDoc] = useState<KnowledgeDocument | null>(null);
    const [editingDocContent, setEditingDocContent] = useState("");
    const [categoryManagerOpen, setCategoryManagerOpen] = useState(false);
    const [versionHistoryOpen, setVersionHistoryOpen] = useState(false);
    const [versionHistoryDoc, setVersionHistoryDoc] = useState<KnowledgeDocument | null>(null);

    // Data hooks
    const { data: documents = [], isLoading: isLoadingDocs } = useKnowledgeDocuments({
        category_id: filterCategoryId,
    });
    const { data: categories = [] } = useKnowledgeCategories();
    const manageDoc = useManageKnowledgeDocument();
    const createCategory = useCreateKnowledgeCategory();
    const updateCategory = useUpdateKnowledgeCategory();
    const deleteCategory = useDeleteKnowledgeCategory();
    const { data: versions = [], isLoading: isLoadingVersions } = useDocumentVersions(
        versionHistoryDoc?.id || null
    );
    const uploadContent = useUploadDocumentContent();
    const downloadContent = useDownloadDocumentContent();

    // Fetch partners for the select
    const { data: partners = [] } = useQuery({
        queryKey: ["partners-list"],
        queryFn: async () => {
            const { data, error } = await supabase
                .from("partners")
                .select("id, name")
                .order("name");
            if (error) throw error;
            return data as { id: string; name: string }[];
        },
    });

    // ============================================================
    // Document handlers
    // ============================================================

    const handleNewDocument = () => {
        setEditingDoc(null);
        setEditingDocContent("");
        setDocDialogOpen(true);
    };

    const handleEditDocument = async (doc: KnowledgeDocument) => {
        try {
            const content = await downloadContent.mutateAsync(doc.storage_path);
            setEditingDoc(doc);
            setEditingDocContent(content);
            setDocDialogOpen(true);
        } catch {
            toast.error("Erro ao carregar conteúdo do documento");
        }
    };

    const handleSaveDocument = async (data: {
        title: string;
        description: string;
        category_id: string;
        partner_id: string | null;
        keywords: string[];
        content: string;
        change_summary: string;
    }) => {
        try {
            const sanitizedTitle = data.title
                .normalize("NFD")
                .replace(/[\u0300-\u036f]/g, "")
                .replace(/[^a-zA-Z0-9\s-]/g, "")
                .trim()
                .replace(/\s+/g, "_")
                .toLowerCase();

            // Always generate a unique path for each version to avoid overwriting history
            const storagePath = `documents/${Date.now()}_${sanitizedTitle}.md`;

            // Upload content to Storage
            await uploadContent.mutateAsync({
                storagePath,
                content: data.content,
            });

            // Create or update document record
            await manageDoc.mutateAsync({
                id: editingDoc?.id,
                title: data.title,
                description: data.description || undefined,
                category_id: data.category_id || undefined,
                partner_id: data.partner_id,
                storage_path: storagePath,
                keywords: data.keywords,
                change_summary: data.change_summary || undefined,
            });

            setDocDialogOpen(false);
        } catch {
            // Toast errors are handled by the mutation hooks
        }
    };

    const handleToggleActive = async (doc: KnowledgeDocument) => {
        await manageDoc.mutateAsync({
            id: doc.id,
            is_active: !doc.is_active,
            change_summary: doc.is_active ? "Desativado" : "Reativado",
        });
    };

    const handleDeleteDocument = async (doc: KnowledgeDocument) => {
        if (!confirm(`Tem certeza que deseja excluir "${doc.title}"?`)) return;
        await manageDoc.mutateAsync({ id: doc.id, delete: true });
    };

    // ============================================================
    // Version history handlers
    // ============================================================

    const handleViewHistory = (doc: KnowledgeDocument) => {
        setVersionHistoryDoc(doc);
        setVersionHistoryOpen(true);
    };

    const handleRestoreVersion = async (version: KnowledgeDocumentVersion) => {
        if (!versionHistoryDoc) return;
        if (!confirm(`Restaurar para a versão ${version.version_number}?`)) return;

        try {
            // Download the old version's content
            const oldContent = await downloadContent.mutateAsync(version.storage_path);

            // Upload it as the new current
            await uploadContent.mutateAsync({
                storagePath: versionHistoryDoc.storage_path,
                content: oldContent,
            });

            // Update the document (triggers new version)
            await manageDoc.mutateAsync({
                id: versionHistoryDoc.id,
                change_summary: `Restaurado da versão ${version.version_number}`,
            });

            setVersionHistoryOpen(false);
            toast.success(`Restaurado para a versão ${version.version_number}`);
        } catch {
            toast.error("Erro ao restaurar versão");
        }
    };

    return (
        <div className="space-y-6">
            {/* Header */}
            <div className="flex items-center justify-between">
                <div>
                    <h1 className="text-3xl font-bold tracking-tight">Base de Conhecimento</h1>
                    <p className="text-muted-foreground">
                        Gerencie os documentos que a Cloudinha usa para responder dúvidas dos estudantes.
                    </p>
                </div>
                <div className="flex gap-2">
                    <Button variant="outline" onClick={() => setCategoryManagerOpen(true)}>
                        <Settings className="h-4 w-4 mr-2" />
                        Categorias
                    </Button>
                    <Button onClick={handleNewDocument}>
                        <Plus className="h-4 w-4 mr-2" />
                        Novo Documento
                    </Button>
                </div>
            </div>

            {/* Filters */}
            <div className="flex gap-4">
                <Select
                    value={filterCategoryId || "all"}
                    onValueChange={(v) => setFilterCategoryId(v === "all" ? undefined : v)}
                >
                    <SelectTrigger className="w-[200px]">
                        <SelectValue placeholder="Todas as categorias" />
                    </SelectTrigger>
                    <SelectContent>
                        <SelectItem value="all">Todas as categorias</SelectItem>
                        {categories.map((cat) => (
                            <SelectItem key={cat.id} value={cat.id}>
                                {cat.label}
                            </SelectItem>
                        ))}
                    </SelectContent>
                </Select>
            </div>

            {/* Table */}
            {isLoadingDocs ? (
                <div className="text-center text-muted-foreground py-12">Carregando documentos...</div>
            ) : (
                <KnowledgeTable
                    documents={documents}
                    onEdit={handleEditDocument}
                    onViewHistory={handleViewHistory}
                    onToggleActive={handleToggleActive}
                    onDelete={handleDeleteDocument}
                />
            )}

            {/* Dialogs */}
            <KnowledgeDocumentDialog
                open={docDialogOpen}
                onOpenChange={setDocDialogOpen}
                document={editingDoc}
                categories={categories}
                partners={partners}
                markdownContent={editingDocContent}
                onSave={handleSaveDocument}
                isSaving={uploadContent.isPending || manageDoc.isPending}
            />

            <KnowledgeCategoryManager
                open={categoryManagerOpen}
                onOpenChange={setCategoryManagerOpen}
                categories={categories}
                onCreateCategory={(p) => createCategory.mutate(p)}
                onUpdateCategory={(p) => updateCategory.mutate(p)}
                onDeleteCategory={(id) => deleteCategory.mutate(id)}
            />

            <KnowledgeVersionHistory
                open={versionHistoryOpen}
                onOpenChange={setVersionHistoryOpen}
                documentTitle={versionHistoryDoc?.title || ""}
                versions={versions}
                isLoading={isLoadingVersions}
                onRestore={handleRestoreVersion}
            />
        </div>
    );
}
