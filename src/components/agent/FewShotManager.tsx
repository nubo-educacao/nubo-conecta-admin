import React, { useState } from "react";
import { useLearningExamples } from "@/hooks/useAgentConfig";
import { LearningExample, CreateLearningExampleDTO } from "@/services/fewShotService";
import { Card, CardHeader, CardTitle, CardContent, CardFooter } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/components/ui/dialog";
import { BookOpen, Plus, Pencil, Trash2, Loader2, Eye } from "lucide-react";
import { cn } from "@/lib/utils";

const CATEGORIES = ["geral", "prouni", "sisu", "match", "candidatura", "perfil", "parceiro"];

const EMPTY_FORM: CreateLearningExampleDTO = {
  intent_category: "geral",
  input_query: "",
  ideal_output: "",
  is_active: true,
  source: "admin",
};

function formatPreview(example: CreateLearningExampleDTO, index = 1): string {
  return `### Exemplo ${index}
**Usuário:** "${example.input_query}"
**Resposta esperada:** "${example.ideal_output}"`;
}

export default function FewShotManager() {
  const { examples, isLoading, isError, createExample, updateExample, deleteExample } =
    useLearningExamples();

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<CreateLearningExampleDTO>(EMPTY_FORM);
  const [previewOpen, setPreviewOpen] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  const openCreate = () => {
    setEditingId(null);
    setForm({ ...EMPTY_FORM });
    setDialogOpen(true);
  };

  const openEdit = (ex: LearningExample) => {
    setEditingId(ex.id);
    setForm({
      intent_category: ex.intent_category,
      input_query: ex.input_query,
      ideal_output: ex.ideal_output,
      is_active: ex.is_active,
      source: ex.source,
    });
    setDialogOpen(true);
  };

  const handleSave = async () => {
    if (!form.input_query.trim() || !form.ideal_output.trim()) return;
    setIsSaving(true);
    try {
      if (editingId) {
        await updateExample({ id: editingId, dto: form });
      } else {
        await createExample(form);
      }
      setDialogOpen(false);
    } finally {
      setIsSaving(false);
    }
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Excluir este learning example?")) return;
    await deleteExample(id);
  };

  if (isLoading) {
    return (
      <div className="flex justify-center p-8">
        <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (isError) {
    return (
      <div className="text-red-500 p-4 border border-red-200 bg-red-50 rounded-lg">
        Erro ao carregar learning examples. Tente atualizar a página.
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <BookOpen className="h-6 w-6 text-primary" />
          <h2 className="text-lg font-semibold">Learning Examples</h2>
        </div>
        <Button onClick={openCreate}>
          <Plus className="h-4 w-4 mr-2" />
          Novo Example
        </Button>
      </div>

      <p className="text-sm text-muted-foreground">
        Examples de conversação injetados no system prompt para calibrar o comportamento da
        Cloudinha. Limitado a ~10 examples (cap de ~2000 tokens). Ordenados por{" "}
        <code className="text-xs bg-muted px-1 rounded">Data de Criação</code>.
      </p>

      {/* List */}
      <div className="grid gap-3">
        {examples.map((ex, i) => (
          <Card
            key={ex.id}
            className={cn("transition-all hover:border-primary/50", !ex.is_active && "opacity-50")}
          >
            <CardHeader className="py-3">
              <div className="flex items-center justify-between gap-2">
                <div className="flex items-center gap-2 flex-wrap">
                  <Badge variant="outline" className="text-xs bg-primary/5">
                    {ex.intent_category}
                  </Badge>
                  <Badge variant="outline" className="text-xs text-muted-foreground">
                    {ex.source}
                  </Badge>
                  {!ex.is_active && (
                    <Badge variant="secondary" className="text-xs">Inativo</Badge>
                  )}
                  <span className="text-xs text-muted-foreground">#{i + 1}</span>
                </div>
                <div className="flex gap-1 shrink-0">
                  <Button variant="ghost" size="icon" onClick={() => openEdit(ex)}>
                    <Pencil className="h-4 w-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="text-destructive hover:bg-destructive/10"
                    onClick={() => handleDelete(ex.id)}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              </div>
            </CardHeader>
            <CardContent className="pt-0 pb-3 border-t bg-muted/10">
              <p className="text-sm font-medium text-foreground/80 truncate">
                👤 {ex.input_query}
              </p>
              <p className="text-xs text-muted-foreground mt-1 line-clamp-2">
                🤖 {ex.ideal_output}
              </p>
            </CardContent>
          </Card>
        ))}
        {examples.length === 0 && (
          <div className="text-center p-8 border border-dashed rounded-lg text-muted-foreground">
            Nenhum learning example cadastrado. Adicione ao menos 1 por categoria.
          </div>
        )}
      </div>

      {/* Create/Edit Dialog */}
      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>
              {editingId ? "Editar Learning Example" : "Novo Learning Example"}
            </DialogTitle>
          </DialogHeader>

          <div className="space-y-4 py-2">
            {/* Category */}
            <div className="space-y-2">
              <Label>Categoria</Label>
              <Select
                value={form.intent_category}
                onValueChange={(v) => setForm((p) => ({ ...p, intent_category: v }))}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {CATEGORIES.map((c) => (
                    <SelectItem key={c} value={c}>
                      {c}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            {/* User message */}
            <div className="space-y-2">
              <Label>Mensagem do Usuário (Query)</Label>
              <Textarea
                rows={2}
                placeholder="Ex: Quais bolsas do ProUni estão abertas?"
                value={form.input_query}
                onChange={(e) => setForm((p) => ({ ...p, input_query: e.target.value }))}
              />
            </div>

            {/* Expected response */}
            <div className="space-y-2">
              <Label>Resposta Esperada (Ideal Output)</Label>
              <Textarea
                rows={4}
                placeholder="Descreva como a Cloudinha deve responder..."
                value={form.ideal_output}
                onChange={(e) => setForm((p) => ({ ...p, ideal_output: e.target.value }))}
              />
            </div>

            {/* Active */}
            <div className="flex items-center gap-2 pt-2">
              <Switch
                checked={form.is_active}
                onCheckedChange={(v) => setForm((p) => ({ ...p, is_active: v }))}
              />
              <Label>Ativo</Label>
            </div>

            {/* Preview */}
            <div className="pt-2 border-t">
              <Button
                variant="outline"
                size="sm"
                type="button"
                onClick={() => setPreviewOpen((p) => !p)}
              >
                <Eye className="h-4 w-4 mr-2" />
                {previewOpen ? "Ocultar Preview" : "Preview no Prompt"}
              </Button>
              {previewOpen && (
                <pre className="mt-3 text-xs bg-muted rounded-lg p-4 whitespace-pre-wrap font-mono">
                  {formatPreview(form)}
                </pre>
              )}
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setDialogOpen(false)}>
              Cancelar
            </Button>
            <Button
              onClick={handleSave}
              disabled={isSaving || !form.input_query.trim() || !form.ideal_output.trim()}
            >
              {isSaving && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
              Salvar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
