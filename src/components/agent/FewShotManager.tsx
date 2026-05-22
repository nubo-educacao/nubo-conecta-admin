import React, { useState } from "react";
import { useFewShotExamples } from "@/hooks/useAgentConfig";
import { useCloudinhaStarters } from "@/hooks/useAgentConfig";
import { FewShotExample, CreateFewShotDTO } from "@/services/fewShotService";
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
const AVAILABLE_TOOLS = [
  "query_educational_catalog",
  "get_student_context",
  "download_knowledge_document",
];

const EMPTY_FORM: CreateFewShotDTO = {
  starter_id: null,
  category: "geral",
  user_message: "",
  expected_tools: [],
  expected_response: "",
  is_active: true,
  sort_order: 0,
};

function formatPreview(example: CreateFewShotDTO, index = 1): string {
  const tools = example.expected_tools.length > 0
    ? example.expected_tools.join(", ")
    : "(nenhuma)";
  return `### Exemplo ${index}
**Usuário:** "${example.user_message}"
**Ferramentas:** ${tools}
**Resposta esperada:** "${example.expected_response}"`;
}

export default function FewShotManager() {
  const { examples, isLoading, isError, createExample, updateExample, deleteExample } =
    useFewShotExamples();
  const { starters } = useCloudinhaStarters();

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<CreateFewShotDTO>(EMPTY_FORM);
  const [previewOpen, setPreviewOpen] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  const openCreate = () => {
    setEditingId(null);
    setForm({ ...EMPTY_FORM, sort_order: examples.length });
    setDialogOpen(true);
  };

  const openEdit = (ex: FewShotExample) => {
    setEditingId(ex.id);
    setForm({
      starter_id: ex.starter_id,
      category: ex.category,
      user_message: ex.user_message,
      expected_tools: ex.expected_tools,
      expected_response: ex.expected_response,
      is_active: ex.is_active,
      sort_order: ex.sort_order,
    });
    setDialogOpen(true);
  };

  const handleSave = async () => {
    if (!form.user_message.trim() || !form.expected_response.trim()) return;
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
    if (!confirm("Excluir este few-shot example?")) return;
    await deleteExample(id);
  };

  const toggleTool = (tool: string) => {
    setForm((prev) => ({
      ...prev,
      expected_tools: prev.expected_tools.includes(tool)
        ? prev.expected_tools.filter((t) => t !== tool)
        : [...prev.expected_tools, tool],
    }));
  };

  const starterLabel = (id: string | null) => {
    if (!id) return "Nenhum";
    const s = starters.find((s) => s.id === id);
    return s ? s.page_route : id;
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
        Erro ao carregar few-shot examples. Tente atualizar a página.
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <BookOpen className="h-6 w-6 text-primary" />
          <h2 className="text-lg font-semibold">Few-Shot Examples</h2>
        </div>
        <Button onClick={openCreate}>
          <Plus className="h-4 w-4 mr-2" />
          Novo Example
        </Button>
      </div>

      <p className="text-sm text-muted-foreground">
        Examples de conversação injetados no system prompt para calibrar o comportamento da
        Cloudinha. Limitado a ~10 examples (cap de ~2000 tokens). Ordenados por{" "}
        <code className="text-xs bg-muted px-1 rounded">sort_order</code>.
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
                    {ex.category}
                  </Badge>
                  {ex.starter_id && (
                    <Badge variant="secondary" className="text-xs">
                      ↗ {starterLabel(ex.starter_id)}
                    </Badge>
                  )}
                  {ex.expected_tools.map((t) => (
                    <Badge key={t} variant="outline" className="text-xs font-mono text-muted-foreground">
                      {t}
                    </Badge>
                  ))}
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
                👤 {ex.user_message}
              </p>
              <p className="text-xs text-muted-foreground mt-1 line-clamp-2">
                🤖 {ex.expected_response}
              </p>
            </CardContent>
          </Card>
        ))}
        {examples.length === 0 && (
          <div className="text-center p-8 border border-dashed rounded-lg text-muted-foreground">
            Nenhum few-shot example cadastrado. Adicione ao menos 1 por categoria de starter.
          </div>
        )}
      </div>

      {/* Create/Edit Dialog */}
      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>
              {editingId ? "Editar Few-Shot Example" : "Novo Few-Shot Example"}
            </DialogTitle>
          </DialogHeader>

          <div className="space-y-4 py-2">
            {/* Category + Starter */}
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label>Categoria</Label>
                <Select
                  value={form.category}
                  onValueChange={(v) => setForm((p) => ({ ...p, category: v }))}
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
              <div className="space-y-2">
                <Label>Starter Vinculado (opcional)</Label>
                <Select
                  value={form.starter_id ?? "none"}
                  onValueChange={(v) =>
                    setForm((p) => ({ ...p, starter_id: v === "none" ? null : v }))
                  }
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="none">Nenhum</SelectItem>
                    {starters.map((s) => (
                      <SelectItem key={s.id} value={s.id}>
                        {s.page_route}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            </div>

            {/* User message */}
            <div className="space-y-2">
              <Label>Mensagem do Usuário</Label>
              <Textarea
                rows={2}
                placeholder="Ex: Quais bolsas do ProUni estão abertas?"
                value={form.user_message}
                onChange={(e) => setForm((p) => ({ ...p, user_message: e.target.value }))}
              />
            </div>

            {/* Tools */}
            <div className="space-y-2">
              <Label>Ferramentas Esperadas</Label>
              <div className="flex flex-wrap gap-2">
                {AVAILABLE_TOOLS.map((tool) => (
                  <button
                    key={tool}
                    type="button"
                    onClick={() => toggleTool(tool)}
                    className={cn(
                      "text-xs font-mono px-3 py-1.5 rounded-full border transition-colors",
                      form.expected_tools.includes(tool)
                        ? "bg-primary text-primary-foreground border-primary"
                        : "bg-background text-muted-foreground border-border hover:border-primary/50"
                    )}
                  >
                    {tool}
                  </button>
                ))}
              </div>
            </div>

            {/* Expected response */}
            <div className="space-y-2">
              <Label>Resposta Esperada</Label>
              <Textarea
                rows={4}
                placeholder="Descreva como a Cloudinha deve responder..."
                value={form.expected_response}
                onChange={(e) => setForm((p) => ({ ...p, expected_response: e.target.value }))}
              />
            </div>

            {/* Sort order + Active */}
            <div className="grid grid-cols-2 gap-4 items-center">
              <div className="space-y-2">
                <Label>Sort Order</Label>
                <Input
                  type="number"
                  min={0}
                  value={form.sort_order}
                  onChange={(e) =>
                    setForm((p) => ({ ...p, sort_order: parseInt(e.target.value) || 0 }))
                  }
                />
              </div>
              <div className="flex items-center gap-2 pt-6">
                <Switch
                  checked={form.is_active}
                  onCheckedChange={(v) => setForm((p) => ({ ...p, is_active: v }))}
                />
                <Label>Ativo</Label>
              </div>
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
              disabled={isSaving || !form.user_message.trim() || !form.expected_response.trim()}
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
