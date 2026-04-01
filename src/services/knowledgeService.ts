import { supabase } from "@/integrations/supabase/client";

// ============================================================
// Types
// ============================================================

export interface KnowledgeCategory {
    id: string;
    name: string;
    label: string;
    created_at: string;
}

export interface KnowledgeDocument {
    id: string;
    title: string;
    description: string | null;
    category_id: string | null;
    category_name: string | null;
    category_label: string | null;
    partner_id: string | null;
    partner_name: string | null;
    storage_path: string;
    is_active: boolean;
    current_version: number;
    created_by: string | null;
    created_at: string;
    updated_at: string;
    keywords: string[];
}

export interface KnowledgeDocumentVersion {
    id: string;
    document_id: string;
    version_number: number;
    storage_path: string;
    change_summary: string | null;
    created_by: string | null;
    created_at: string;
}

// ============================================================
// Categories
// ============================================================

export async function getKnowledgeCategories(): Promise<KnowledgeCategory[]> {
    const { data, error } = await (supabase.from as any)("knowledge_categories")
        .select("*")
        .order("name", { ascending: true });

    if (error) {
        console.error("Error fetching knowledge categories:", error);
        throw error;
    }

    return data as KnowledgeCategory[];
}

export async function createKnowledgeCategory(params: {
    name: string;
    label: string;
}): Promise<KnowledgeCategory> {
    const { data, error } = await (supabase.from as any)("knowledge_categories")
        .insert({ name: params.name.toLowerCase().trim(), label: params.label.trim() })
        .select()
        .single();

    if (error) {
        console.error("Error creating knowledge category:", error);
        throw error;
    }

    return data as KnowledgeCategory;
}

export async function updateKnowledgeCategory(
    id: string,
    params: { name?: string; label?: string }
): Promise<KnowledgeCategory> {
    const updateData: Record<string, string> = {};
    if (params.name) updateData.name = params.name.toLowerCase().trim();
    if (params.label) updateData.label = params.label.trim();

    const { data, error } = await (supabase.from as any)("knowledge_categories")
        .update(updateData)
        .eq("id", id)
        .select()
        .single();

    if (error) {
        console.error("Error updating knowledge category:", error);
        throw error;
    }

    return data as KnowledgeCategory;
}

export async function deleteKnowledgeCategory(id: string): Promise<void> {
    const { error } = await (supabase.from as any)("knowledge_categories")
        .delete()
        .eq("id", id);

    if (error) {
        console.error("Error deleting knowledge category:", error);
        throw error;
    }
}

// ============================================================
// Documents (via RPCs)
// ============================================================

export async function getKnowledgeDocuments(filters?: {
    category_id?: string;
    partner_id?: string;
    is_active?: boolean;
}): Promise<KnowledgeDocument[]> {
    const { data, error } = await (supabase.rpc as any)("get_knowledge_documents", {
        p_category_id: filters?.category_id || null,
        p_partner_id: filters?.partner_id || null,
        p_is_active: filters?.is_active ?? null,
    });

    if (error) {
        console.error("Error fetching knowledge documents:", error);
        throw error;
    }

    return (data || []) as KnowledgeDocument[];
}

export async function manageKnowledgeDocument(params: {
    id?: string;
    title?: string;
    description?: string;
    category_id?: string;
    partner_id?: string | null;
    storage_path?: string;
    is_active?: boolean;
    keywords?: string[];
    change_summary?: string;
    delete?: boolean;
}): Promise<{ status: string; action: string; id: string; version?: number }> {
    const { data, error } = await (supabase.rpc as any)("manage_knowledge_document", {
        p_id: params.id || null,
        p_title: params.title || null,
        p_description: params.description || null,
        p_category_id: params.category_id || null,
        p_partner_id: params.partner_id ?? null,
        p_storage_path: params.storage_path || null,
        p_is_active: params.is_active ?? null,
        p_keywords: params.keywords || null,
        p_change_summary: params.change_summary || null,
        p_delete: params.delete || false,
    });

    if (error) {
        console.error("Error managing knowledge document:", error);
        throw error;
    }

    if (data?.status === "error") {
        throw new Error(data.message);
    }

    return data;
}

// ============================================================
// Versions
// ============================================================

export async function getDocumentVersions(documentId: string): Promise<KnowledgeDocumentVersion[]> {
    const { data, error } = await (supabase.from as any)("knowledge_document_versions")
        .select("*")
        .eq("document_id", documentId)
        .order("version_number", { ascending: false });

    if (error) {
        console.error("Error fetching document versions:", error);
        throw error;
    }

    return data as KnowledgeDocumentVersion[];
}

// ============================================================
// Storage (Bucket: knowledge-base)
// ============================================================

export async function uploadDocumentContent(storagePath: string, content: string): Promise<string> {
    const blob = new Blob([content], { type: "text/markdown" });

    const { error } = await supabase.storage
        .from("knowledge-base")
        .upload(storagePath, blob, { upsert: true, contentType: "text/markdown" });

    if (error) {
        console.error("Error uploading document content:", error);
        throw error;
    }

    return storagePath;
}

export async function downloadDocumentContent(storagePath: string): Promise<string> {
    const { data, error } = await supabase.storage
        .from("knowledge-base")
        .download(storagePath);

    if (error) {
        console.error("Error downloading document content:", error);
        throw error;
    }

    return await data.text();
}
