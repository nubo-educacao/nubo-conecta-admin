import React from "react";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
} from "@/components/ui/dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { RotateCcw } from "lucide-react";
import type { KnowledgeDocumentVersion } from "@/services/knowledgeService";

interface KnowledgeVersionHistoryProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    documentTitle: string;
    versions: KnowledgeDocumentVersion[];
    isLoading: boolean;
    onRestore: (version: KnowledgeDocumentVersion) => void;
}

export default function KnowledgeVersionHistory({
    open,
    onOpenChange,
    documentTitle,
    versions,
    isLoading,
    onRestore,
}: KnowledgeVersionHistoryProps) {
    const formatDate = (dateStr: string) => {
        return new Date(dateStr).toLocaleString("pt-BR", {
            day: "2-digit",
            month: "2-digit",
            year: "numeric",
            hour: "2-digit",
            minute: "2-digit",
        });
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="max-w-lg max-h-[80vh] overflow-y-auto">
                <DialogHeader>
                    <DialogTitle>Histórico de Versões — {documentTitle}</DialogTitle>
                </DialogHeader>

                <div className="space-y-3 py-4">
                    {isLoading ? (
                        <p className="text-sm text-muted-foreground text-center py-4">Carregando...</p>
                    ) : versions.length === 0 ? (
                        <p className="text-sm text-muted-foreground text-center py-4">
                            Nenhuma versão anterior encontrada.
                        </p>
                    ) : (
                        versions.map((version) => (
                            <div
                                key={version.id}
                                className="flex items-start justify-between gap-3 p-3 rounded-md border"
                            >
                                <div className="space-y-1 flex-1">
                                    <div className="flex items-center gap-2">
                                        <Badge variant="outline">v{version.version_number}</Badge>
                                        <span className="text-xs text-muted-foreground">
                                            {formatDate(version.created_at)}
                                        </span>
                                    </div>
                                    {version.change_summary && (
                                        <p className="text-sm text-muted-foreground">
                                            {version.change_summary}
                                        </p>
                                    )}
                                </div>
                                <Button
                                    variant="ghost"
                                    size="sm"
                                    onClick={() => onRestore(version)}
                                    title="Restaurar esta versão"
                                    className="shrink-0"
                                >
                                    <RotateCcw className="h-4 w-4 mr-1" />
                                    Restaurar
                                </Button>
                            </div>
                        ))
                    )}
                </div>
            </DialogContent>
        </Dialog>
    );
}
