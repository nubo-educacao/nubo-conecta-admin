import React, { useState, useEffect } from "react";
import KnowledgeTestChat from "@/components/knowledge/KnowledgeTestChat";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import { Badge } from "@/components/ui/badge";
import { X, Upload } from "lucide-react";
import { useRef } from "react";
import type { KnowledgeDocument, KnowledgeCategory } from "@/services/knowledgeService";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import { Loader2 } from "lucide-react";

interface Partner {
    id: string;
    name: string;
}

interface KnowledgeDocumentDialogProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    document: KnowledgeDocument | null;
    categories: KnowledgeCategory[];
    partners: Partner[];
    markdownContent: string;
    onSave: (data: {
        title: string;
        description: string;
        category_id: string;
        partner_id: string | null;
        keywords: string[];
        content: string;
        change_summary: string;
    }) => void;
    isSaving: boolean;
}

export default function KnowledgeDocumentDialog({
    open,
    onOpenChange,
    document,
    categories,
    partners,
    markdownContent,
    onSave,
    isSaving,
}: KnowledgeDocumentDialogProps) {
    const [title, setTitle] = useState("");
    const [description, setDescription] = useState("");
    const [categoryId, setCategoryId] = useState("");
    const [partnerId, setPartnerId] = useState<string | null>(null);
    const [keywords, setKeywords] = useState<string[]>([]);
    const [keywordInput, setKeywordInput] = useState("");
    const [content, setContent] = useState("");
    const [changeSummary, setChangeSummary] = useState("");
    const [showPreview, setShowPreview] = useState(false);
    const [isConverting, setIsConverting] = useState(false);
    const fileInputRef = useRef<HTMLInputElement>(null);

    const handleFileImport = async (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (!file) return;

        if (file.name.endsWith(".pdf")) {
            try {
                setIsConverting(true);
                toast.info("Lendo PDF. Isso pode levar alguns segundos...");
                
                // Read file as base64
                const reader = new FileReader();
                const base64Promise = new Promise<string>((resolve, reject) => {
                    reader.onload = () => {
                        const b64 = (reader.result as string).split(",")[1];
                        resolve(b64);
                    };
                    reader.onerror = reject;
                });
                reader.readAsDataURL(file);
                const pdfBase64 = await base64Promise;

                const { data, error } = await supabase.functions.invoke("pdf-to-markdown", {
                    body: { pdfBase64 }
                });

                if (error) {
                    console.error("Function error details:", error);
                    // Handle specific timeout/gateway errors
                    if (error.message?.includes("504") || error.message?.includes("502")) {
                        throw new Error("O documento é muito grande para conversão automática (Timeout). Tente reduzir o PDF ou copiar o texto manualmente.");
                    }
                    throw new Error(error.message || "Erro ao processar PDF");
                }
                if (data?.error) {
                    if (data.error.includes("abort") || data.error.includes("timeout")) {
                         throw new Error("O processamento demorou demais. Tente um arquivo menor ou divida o documento.");
                    }
                    throw new Error(data.error);
                }

                if (data?.markdown) {
                    setContent(data.markdown);
                    
                    if (data.title && !title.trim()) {
                        setTitle(data.title.substring(0, 150)); // Safely limit length
                    } else if (!title.trim()) {
                        const baseName = file.name.replace(/\.[^.]+$/, "").replace(/[_-]/g, " ");
                        setTitle(baseName);
                    }

                    if (data.description && !description.trim()) {
                        setDescription(data.description);
                    }

                    if (data.category_name) {
                        const categoryNameLower = data.category_name.toLowerCase();
                        const matchingCategory = categories.find(c => c.name.toLowerCase() === categoryNameLower);
                        if (matchingCategory) {
                            setCategoryId(matchingCategory.id);
                        }
                    }

                    if (data.partner_name && data.partner_name.trim() !== "") {
                        const pNameStr = data.partner_name.toLowerCase();
                        const matchingPartner = partners.find(p => p.name.toLowerCase().includes(pNameStr) || pNameStr.includes(p.name.toLowerCase()));
                        if (matchingPartner) {
                            setPartnerId(matchingPartner.id);
                        }
                    }

                    if (data.keywords && Array.isArray(data.keywords)) {
                        setKeywords(prev => {
                            const newSet = new Set([...prev, ...data.keywords]);
                            return Array.from(newSet);
                        });
                    }

                    toast.success("PDF analisado e dados preenchidos com sucesso!");
                } else {
                    throw new Error("Resposta da conversão está vazia.");
                }
            } catch (err: any) {
                console.error("Erro na conversão de PDF:", err);
                toast.error(`Falha ao converter PDF: ${err.message}`);
            } finally {
                setIsConverting(false);
                if (e.target) e.target.value = "";
            }
            return;
        }

        const reader = new FileReader();
        reader.onload = (ev) => {
            const text = ev.target?.result as string;
            setContent(text || "");
            // Pre-fill title from filename if empty
            if (!title.trim()) {
                const baseName = file.name.replace(/\.[^.]+$/, "").replace(/[_-]/g, " ");
                setTitle(baseName);
            }
        };
        reader.readAsText(file, "UTF-8");
        e.target.value = "";
    };

    const isEditing = !!document;

    useEffect(() => {
        if (document) {
            setTitle(document.title);
            setDescription(document.description || "");
            setCategoryId(document.category_id || "");
            setPartnerId(document.partner_id);
            setKeywords(document.keywords || []);
            setContent(markdownContent);
            setChangeSummary("");
        } else {
            setTitle("");
            setDescription("");
            setCategoryId("");
            setPartnerId(null);
            setKeywords([]);
            setContent("");
            setChangeSummary("");
        }
    }, [document, markdownContent, open]);

    const handleAddKeyword = () => {
        const kw = keywordInput.toLowerCase().trim();
        if (kw && !keywords.includes(kw)) {
            setKeywords([...keywords, kw]);
        }
        setKeywordInput("");
    };

    const handleKeywordKeyDown = (e: React.KeyboardEvent) => {
        if (e.key === "Enter") {
            e.preventDefault();
            handleAddKeyword();
        }
    };

    const handleRemoveKeyword = (kw: string) => {
        setKeywords(keywords.filter((k) => k !== kw));
    };

    const handleSubmit = () => {
        if (!title.trim() || !content.trim()) return;
        onSave({
            title: title.trim(),
            description: description.trim(),
            category_id: categoryId,
            partner_id: partnerId,
            keywords,
            content,
            change_summary: changeSummary.trim(),
        });
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="max-w-4xl max-h-[90vh] overflow-y-auto">
                <DialogHeader>
                    <DialogTitle>
                        {isEditing ? "Editar Documento" : "Novo Documento"}
                    </DialogTitle>
                </DialogHeader>

                <div className="grid gap-4 py-4">
                    {/* Row 1: Title */}
                    <div className="space-y-2">
                        <Label htmlFor="doc-title">Título *</Label>
                        <Input
                            id="doc-title"
                            value={title}
                            onChange={(e) => setTitle(e.target.value)}
                            placeholder="Ex: Edital Instituto Ponte 2026"
                        />
                    </div>

                    {/* Row 2: Description */}
                    <div className="space-y-2">
                        <Label htmlFor="doc-description">Descrição</Label>
                        <Input
                            id="doc-description"
                            value={description}
                            onChange={(e) => setDescription(e.target.value)}
                            placeholder="Breve descrição do documento"
                        />
                    </div>

                    {/* Row 3: Category + Partner */}
                    <div className="grid grid-cols-2 gap-4">
                        <div className="space-y-2">
                            <Label>Categoria</Label>
                            <Select value={categoryId} onValueChange={setCategoryId}>
                                <SelectTrigger>
                                    <SelectValue placeholder="Selecione..." />
                                </SelectTrigger>
                                <SelectContent>
                                    {categories.map((cat) => (
                                        <SelectItem key={cat.id} value={cat.id}>
                                            {cat.label}
                                        </SelectItem>
                                    ))}
                                </SelectContent>
                            </Select>
                        </div>

                        <div className="space-y-2">
                            <Label>Parceiro (opcional)</Label>
                            <Select
                                value={partnerId || "none"}
                                onValueChange={(v) => setPartnerId(v === "none" ? null : v)}
                            >
                                <SelectTrigger>
                                    <SelectValue placeholder="Nenhum" />
                                </SelectTrigger>
                                <SelectContent>
                                    <SelectItem value="none">Nenhum</SelectItem>
                                    {partners.map((p) => (
                                        <SelectItem key={p.id} value={p.id}>
                                            {p.name}
                                        </SelectItem>
                                    ))}
                                </SelectContent>
                            </Select>
                        </div>
                    </div>

                    {/* Row 4: Keywords */}
                    <div className="space-y-2">
                        <Label>Keywords (trigger words para a Cloudinha)</Label>
                        <div className="flex gap-2">
                            <Input
                                value={keywordInput}
                                onChange={(e) => setKeywordInput(e.target.value)}
                                onKeyDown={handleKeywordKeyDown}
                                placeholder="Digite e pressione Enter"
                                className="flex-1"
                            />
                            <Button type="button" variant="secondary" onClick={handleAddKeyword}>
                                Adicionar
                            </Button>
                        </div>
                        {keywords.length > 0 && (
                            <div className="flex flex-wrap gap-1 mt-2">
                                {keywords.map((kw) => (
                                    <Badge key={kw} variant="secondary" className="gap-1">
                                        {kw}
                                        <button
                                            onClick={() => handleRemoveKeyword(kw)}
                                            className="ml-1 hover:text-destructive"
                                        >
                                            <X className="h-3 w-3" />
                                        </button>
                                    </Badge>
                                ))}
                            </div>
                        )}
                    </div>

                    {/* Row 5: Markdown Editor */}
                    <div className="space-y-2">
                        <div className="flex items-center justify-between">
                            <Label>Conteúdo (Markdown) *</Label>
                            <div className="flex items-center gap-1">
                                <input
                                    ref={fileInputRef}
                                    type="file"
                                    accept=".md,.txt,.pdf"
                                    className="hidden"
                                    onChange={handleFileImport}
                                />
                                <Button
                                    type="button"
                                    variant="ghost"
                                    size="sm"
                                    onClick={() => fileInputRef.current?.click()}
                                    disabled={isConverting}
                                >
                                    {isConverting ? (
                                        <Loader2 className="h-4 w-4 mr-1 animate-spin" />
                                    ) : (
                                        <Upload className="h-4 w-4 mr-1" />
                                    )}
                                    {isConverting ? "Convertendo..." : "Importar arquivo"}
                                </Button>
                                <Button
                                    type="button"
                                    variant="ghost"
                                    size="sm"
                                    onClick={() => setShowPreview(!showPreview)}
                                >
                                    {showPreview ? "Editar" : "Preview"}
                                </Button>
                            </div>
                        </div>
                        {showPreview ? (
                            <div className="border rounded-md p-4 min-h-[300px] max-h-[400px] overflow-y-auto prose prose-sm dark:prose-invert max-w-none">
                                <pre className="whitespace-pre-wrap text-sm font-mono">{content}</pre>
                            </div>
                        ) : (
                            <Textarea
                                value={content}
                                onChange={(e) => setContent(e.target.value)}
                                placeholder="Cole ou escreva o conteúdo em Markdown aqui..."
                                className="min-h-[300px] font-mono text-sm"
                                disabled={isConverting}
                            />
                        )}
                    </div>

                    {/* Row 6: Test Knowledge Chat */}
                    <KnowledgeTestChat
                        markdownContent={content}
                        documentTitle={title || "Documento"}
                    />

                    {/* Row 7: Change Summary (only for edits) */}
                    {isEditing && (
                        <div className="space-y-2">
                            <Label htmlFor="change-summary">Resumo da alteração</Label>
                            <Input
                                id="change-summary"
                                value={changeSummary}
                                onChange={(e) => setChangeSummary(e.target.value)}
                                placeholder="Ex: Atualizado prazo de inscrição para Março"
                            />
                        </div>
                    )}
                </div>

                <DialogFooter>
                    <Button variant="outline" onClick={() => onOpenChange(false)} disabled={isConverting}>
                        Cancelar
                    </Button>
                    <Button
                        onClick={handleSubmit}
                        disabled={!title.trim() || !content.trim() || isSaving || isConverting}
                    >
                        {isSaving ? "Salvando..." : isEditing ? "Salvar Alterações" : "Criar Documento"}
                    </Button>
                </DialogFooter>
            </DialogContent>
        </Dialog>
    );
}
