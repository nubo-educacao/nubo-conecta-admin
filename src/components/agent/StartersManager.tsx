import React, { useState } from "react";
import { useCloudinhaStarters } from "@/hooks/useAgentConfig";
import { CloudinhaStarter } from "@/services/agentConfigService";
import { Card, CardHeader, CardTitle, CardContent, CardDescription, CardFooter } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import { MessageSquare, Plus, Save, Trash2, Loader2, GripVertical } from "lucide-react";

export default function StartersManager() {
  const { starters, isLoading, isError, upsertStarter, deleteStarter } = useCloudinhaStarters();
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editForm, setEditForm] = useState<Partial<CloudinhaStarter> | null>(null);

  if (isLoading) {
    return <div className="flex justify-center p-8"><Loader2 className="h-8 w-8 animate-spin text-muted-foreground" /></div>;
  }

  if (isError) {
    return <div className="text-red-500 p-4 border border-red-200 bg-red-50 rounded-lg">Erro ao carregar starters. Tente atualizar a página.</div>;
  }

  const handleEdit = (starter: CloudinhaStarter) => {
    setEditingId(starter.id);
    setEditForm({ ...starter });
  };

  const handleAddNew = () => {
    setEditingId("new");
    setEditForm({
      page_route: "/",
      route_priority: 0,
      intro_message: "Oi! Sou a Cloudinha.",
      starters: ["Pergunta 1?"],
      is_active: true
    });
  };

  const handleCancel = () => {
    setEditingId(null);
    setEditForm(null);
  };

  const handleSave = async () => {
    if (editForm) {
      await upsertStarter(editForm);
      setEditingId(null);
      setEditForm(null);
    }
  };

  const handleDelete = async (id: string) => {
    if (confirm("Tem certeza que deseja excluir esta configuração?")) {
      await deleteStarter(id);
    }
  };

  const updateStarterText = (index: number, text: string) => {
    if (editForm && editForm.starters) {
      const newStarters = [...editForm.starters];
      newStarters[index] = text;
      setEditForm({ ...editForm, starters: newStarters });
    }
  };

  const addStarterField = () => {
    if (editForm && editForm.starters) {
      setEditForm({ ...editForm, starters: [...editForm.starters, ""] });
    }
  };

  const removeStarterField = (index: number) => {
    if (editForm && editForm.starters) {
      const newStarters = [...editForm.starters];
      newStarters.splice(index, 1);
      setEditForm({ ...editForm, starters: newStarters });
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-2">
          <MessageSquare className="h-6 w-6 text-primary" />
          <h2 className="text-lg font-semibold">Conversation Starters (Chips)</h2>
        </div>
        <Button onClick={handleAddNew} disabled={editingId !== null}>
          <Plus className="h-4 w-4 mr-2" />
          Nova Rota
        </Button>
      </div>
      
      <p className="text-sm text-muted-foreground mb-6">
        Defina as perguntas de início rápido que aparecerão como chips acima do input do chat, customizadas pela rota (página) onde o usuário estiver.
      </p>

      {/* Forms/Edit Mode */}
      {editingId && editForm && (
        <Card className="border-primary ring-1 ring-primary/20 sticky top-4 z-10 shadow-lg">
          <CardHeader>
            <CardTitle>{editingId === "new" ? "Nova Configuração de Starter" : `Editando Rota: ${editForm.page_route}`}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label htmlFor="page_route">Rota da Página (exact match ou regex leve)</Label>
                <Input 
                  id="page_route" 
                  value={editForm.page_route || ""} 
                  onChange={(e) => setEditForm({...editForm, page_route: e.target.value})} 
                  placeholder="Ex: /oportunidades" 
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="route_priority">Prioridade (maior vence colisões)</Label>
                <Input 
                  id="route_priority" 
                  type="number"
                  value={editForm.route_priority || 0} 
                  onChange={(e) => setEditForm({...editForm, route_priority: parseInt(e.target.value) || 0})} 
                />
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="intro_message">Mensagem de Introdução (Opcional)</Label>
              <Textarea 
                id="intro_message" 
                value={editForm.intro_message || ""} 
                onChange={(e) => setEditForm({...editForm, intro_message: e.target.value})} 
                rows={2}
                placeholder="Ex: Oi! Você quer saber sobre cursos de tecnologia?"
              />
            </div>
            
            <div className="space-y-3 pt-4 border-t">
              <Label className="flex justify-between items-center">
                <span>Botões de Starter (Max 4 recomendados)</span>
                <Button type="button" variant="outline" size="sm" onClick={addStarterField}>
                  <Plus className="h-3 w-3 mr-1" /> Add
                </Button>
              </Label>
              {editForm.starters && editForm.starters.map((starterText, idx) => (
                <div key={idx} className="flex items-center gap-2">
                  <GripVertical className="h-4 w-4 text-muted-foreground shrink-0 cursor-grab" />
                  <Input 
                    value={starterText} 
                    onChange={(e) => updateStarterText(idx, e.target.value)} 
                    placeholder="Escreva a pergunta de exemplo..."
                  />
                  <Button variant="ghost" size="icon" className="text-destructive shrink-0" onClick={() => removeStarterField(idx)}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              ))}
            </div>
          </CardContent>
          <CardFooter className="flex justify-end gap-2 bg-muted/30 border-t">
            <Button variant="outline" onClick={handleCancel}>Cancelar</Button>
            <Button onClick={handleSave}>
              <Save className="h-4 w-4 mr-2" /> Salvar Starters
            </Button>
          </CardFooter>
        </Card>
      )}

      {/* List Mode */}
      <div className="grid gap-4">
        {starters.map((starter) => (
          <Card key={starter.id} className={`transition-all ${editingId === starter.id ? 'opacity-50 pointer-events-none' : 'hover:border-primary/50'}`}>
            <CardHeader className="py-4">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <Badge variant="outline" className="text-sm bg-primary/5">{starter.page_route}</Badge>
                  {starter.is_active ? (
                    <Badge variant="default" className="bg-green-500 hover:bg-green-600">Ativo</Badge>
                  ) : (
                    <Badge variant="secondary">Inativo</Badge>
                  )}
                  <span className="text-xs text-muted-foreground">Prioridade: p{starter.route_priority}</span>
                </div>
                <div className="flex gap-2">
                  <Button variant="outline" size="sm" onClick={() => handleEdit(starter)}>Editar</Button>
                  <Button variant="ghost" size="sm" className="text-destructive hover:bg-destructive/10" onClick={() => handleDelete(starter.id)}>Excluir</Button>
                </div>
              </div>
            </CardHeader>
            <CardContent className="py-4 border-t bg-muted/10">
              {starter.intro_message && (
                <p className="text-sm text-muted-foreground italic mb-3">"{starter.intro_message}"</p>
              )}
              <div className="flex flex-wrap gap-2">
                {starter.starters.map((s, i) => (
                  <div key={i} className="text-xs bg-background border px-3 py-1.5 rounded-full text-foreground/80 shadow-sm">
                    {s}
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        ))}
        {starters.length === 0 && !isLoading && (
          <div className="text-center p-8 border border-dashed rounded-lg text-muted-foreground">
            Nenhum starter configurado. Adicione a rota "/" (Home) para iniciar.
          </div>
        )}
      </div>
    </div>
  );
}
