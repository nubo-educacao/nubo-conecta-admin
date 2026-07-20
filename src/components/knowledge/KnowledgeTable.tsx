import React from "react";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import { Pencil, History, Trash2 } from "lucide-react";
import type { KnowledgeDocument } from "@/services/knowledgeService";

interface KnowledgeTableProps {
    documents: KnowledgeDocument[];
    onEdit: (doc: KnowledgeDocument) => void;
    onViewHistory: (doc: KnowledgeDocument) => void;
    onToggleActive: (doc: KnowledgeDocument) => void;
    onDelete: (doc: KnowledgeDocument) => void;
}

export default function KnowledgeTable({
    documents,
    onEdit,
    onViewHistory,
    onToggleActive,
    onDelete,
}: KnowledgeTableProps) {
    return (
        <div className="rounded-md border">
            <Table>
                <TableHeader>
                    <TableRow>
                        <TableHead>Título</TableHead>
                        <TableHead>Categoria</TableHead>
                        <TableHead>Oportunidades Parceiras</TableHead>
                        <TableHead>Keywords</TableHead>
                        <TableHead className="text-center">Versão</TableHead>
                        <TableHead className="text-center">Ativo</TableHead>
                        <TableHead className="text-center">Ações</TableHead>
                    </TableRow>
                </TableHeader>
                <TableBody>
                    {documents.length === 0 ? (
                        <TableRow>
                            <TableCell colSpan={7} className="text-center text-muted-foreground py-8">
                                Nenhum documento encontrado. Clique em "Novo Documento" para começar.
                            </TableCell>
                        </TableRow>
                    ) : (
                        documents.map((doc) => (
                            <TableRow key={doc.id} className={!doc.is_active ? "opacity-50" : ""}>
                                <TableCell className="font-medium max-w-[200px] truncate">
                                    {doc.title}
                                </TableCell>
                                <TableCell>
                                    {doc.category_label && (
                                        <Badge variant="secondary">{doc.category_label}</Badge>
                                    )}
                                </TableCell>
                                <TableCell className="text-sm text-muted-foreground">
                                    {doc.partner_opportunities.length > 0 ? (
                                        <div className="flex flex-wrap gap-1 max-w-[220px]">
                                            {doc.partner_opportunities.map((po) => (
                                                <Badge key={po.id} variant="outline" className="text-xs">
                                                    {po.name}
                                                </Badge>
                                            ))}
                                        </div>
                                    ) : (
                                        "—"
                                    )}
                                </TableCell>
                                <TableCell>
                                    <div className="flex flex-wrap gap-1 max-w-[200px]">
                                        {doc.keywords.slice(0, 3).map((kw) => (
                                            <Badge key={kw} variant="outline" className="text-xs">
                                                {kw}
                                            </Badge>
                                        ))}
                                        {doc.keywords.length > 3 && (
                                            <Badge variant="outline" className="text-xs">
                                                +{doc.keywords.length - 3}
                                            </Badge>
                                        )}
                                    </div>
                                </TableCell>
                                <TableCell className="text-center">
                                    <Badge variant="outline">v{doc.current_version}</Badge>
                                </TableCell>
                                <TableCell className="text-center">
                                    <Switch
                                        checked={doc.is_active}
                                        onCheckedChange={() => onToggleActive(doc)}
                                    />
                                </TableCell>
                                <TableCell>
                                    <div className="flex items-center justify-center gap-1">
                                        <Button
                                            variant="ghost"
                                            size="icon"
                                            onClick={() => onEdit(doc)}
                                            title="Editar"
                                        >
                                            <Pencil className="h-4 w-4" />
                                        </Button>
                                        <Button
                                            variant="ghost"
                                            size="icon"
                                            onClick={() => onViewHistory(doc)}
                                            title="Histórico de versões"
                                        >
                                            <History className="h-4 w-4" />
                                        </Button>
                                        <Button
                                            variant="ghost"
                                            size="icon"
                                            onClick={() => onDelete(doc)}
                                            title="Excluir"
                                            className="text-destructive hover:text-destructive"
                                        >
                                            <Trash2 className="h-4 w-4" />
                                        </Button>
                                    </div>
                                </TableCell>
                            </TableRow>
                        ))
                    )}
                </TableBody>
            </Table>
        </div>
    );
}
