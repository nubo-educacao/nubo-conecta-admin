import React, { useState } from "react";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Pencil, Trash2, Plus, Check, X } from "lucide-react";
import type { KnowledgeCategory } from "@/services/knowledgeService";

interface KnowledgeCategoryManagerProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    categories: KnowledgeCategory[];
    onCreateCategory: (params: { name: string; label: string }) => void;
    onUpdateCategory: (params: { id: string; name?: string; label?: string }) => void;
    onDeleteCategory: (id: string) => void;
}

export default function KnowledgeCategoryManager({
    open,
    onOpenChange,
    categories,
    onCreateCategory,
    onUpdateCategory,
    onDeleteCategory,
}: KnowledgeCategoryManagerProps) {
    const [newName, setNewName] = useState("");
    const [newLabel, setNewLabel] = useState("");
    const [editingId, setEditingId] = useState<string | null>(null);
    const [editName, setEditName] = useState("");
    const [editLabel, setEditLabel] = useState("");

    const handleCreate = () => {
        if (!newName.trim() || !newLabel.trim()) return;
        onCreateCategory({ name: newName, label: newLabel });
        setNewName("");
        setNewLabel("");
    };

    const startEdit = (cat: KnowledgeCategory) => {
        setEditingId(cat.id);
        setEditName(cat.name);
        setEditLabel(cat.label);
    };

    const saveEdit = () => {
        if (!editingId || !editName.trim() || !editLabel.trim()) return;
        onUpdateCategory({ id: editingId, name: editName, label: editLabel });
        setEditingId(null);
    };

    const cancelEdit = () => {
        setEditingId(null);
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="max-w-md">
                <DialogHeader>
                    <DialogTitle>Gerenciar Categorias</DialogTitle>
                </DialogHeader>

                <div className="space-y-4 py-4">
                    {/* Existing categories */}
                    <div className="space-y-2">
                        {categories.map((cat) => (
                            <div key={cat.id} className="flex items-center gap-2 p-2 rounded-md border">
                                {editingId === cat.id ? (
                                    <>
                                        <Input
                                            value={editName}
                                            onChange={(e) => setEditName(e.target.value)}
                                            placeholder="slug"
                                            className="flex-1 h-8 text-sm"
                                        />
                                        <Input
                                            value={editLabel}
                                            onChange={(e) => setEditLabel(e.target.value)}
                                            placeholder="Label"
                                            className="flex-1 h-8 text-sm"
                                        />
                                        <Button variant="ghost" size="icon" className="h-8 w-8" onClick={saveEdit}>
                                            <Check className="h-4 w-4 text-green-600" />
                                        </Button>
                                        <Button variant="ghost" size="icon" className="h-8 w-8" onClick={cancelEdit}>
                                            <X className="h-4 w-4" />
                                        </Button>
                                    </>
                                ) : (
                                    <>
                                        <div className="flex-1">
                                            <span className="text-sm font-medium">{cat.label}</span>
                                            <span className="text-xs text-muted-foreground ml-2">({cat.name})</span>
                                        </div>
                                        <Button variant="ghost" size="icon" className="h-8 w-8" onClick={() => startEdit(cat)}>
                                            <Pencil className="h-3.5 w-3.5" />
                                        </Button>
                                        <Button
                                            variant="ghost"
                                            size="icon"
                                            className="h-8 w-8 text-destructive hover:text-destructive"
                                            onClick={() => onDeleteCategory(cat.id)}
                                        >
                                            <Trash2 className="h-3.5 w-3.5" />
                                        </Button>
                                    </>
                                )}
                            </div>
                        ))}
                    </div>

                    {/* New category form */}
                    <div className="border-t pt-4">
                        <Label className="text-sm text-muted-foreground mb-2 block">Nova Categoria</Label>
                        <div className="flex gap-2">
                            <Input
                                value={newName}
                                onChange={(e) => setNewName(e.target.value)}
                                placeholder="slug (ex: enem)"
                                className="flex-1 h-9"
                            />
                            <Input
                                value={newLabel}
                                onChange={(e) => setNewLabel(e.target.value)}
                                placeholder="Label (ex: ENEM)"
                                className="flex-1 h-9"
                            />
                            <Button
                                size="sm"
                                onClick={handleCreate}
                                disabled={!newName.trim() || !newLabel.trim()}
                                className="h-9"
                            >
                                <Plus className="h-4 w-4" />
                            </Button>
                        </div>
                    </div>
                </div>
            </DialogContent>
        </Dialog>
    );
}
