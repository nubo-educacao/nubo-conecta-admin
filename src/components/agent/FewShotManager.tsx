import { useState } from 'react';
import { useFewShotExamples } from '@/hooks/useAgentConfig';
import type { FewShotExample, CreateFewShotDTO } from '@/services/fewShotService';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { Switch } from '@/components/ui/switch';
import { Card, CardContent } from '@/components/ui/card';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog';
import { Loader2, Pencil, Trash2, Plus } from 'lucide-react';

const empty: CreateFewShotDTO = {
  intent_category: '', input_query: '', ideal_output: '', reasoning: '', is_active: true,
};

export default function FewShotManager() {
  const { examples, isLoading, isError, refetch, createExample, updateExample, deleteExample } = useFewShotExamples();
  const [open, setOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<CreateFewShotDTO>(empty);
  const [saving, setSaving] = useState(false);
  function edit(example?: FewShotExample) {
    setEditingId(example?.id ?? null);
    setForm(example ? {
      intent_category: example.intent_category, input_query: example.input_query,
      ideal_output: example.ideal_output, reasoning: example.reasoning, is_active: example.is_active,
    } : { ...empty });
    setOpen(true);
  }
  async function save() {
    if (!form.input_query.trim() || !form.ideal_output.trim()) return;
    setSaving(true);
    try {
      if (editingId) await updateExample({ id: editingId, dto: form });
      else await createExample(form);
      setOpen(false);
    } catch {
      // The mutation hook reports the error; keep the unsaved form available.
    } finally { setSaving(false); }
  }
  async function remove(id: string) {
    if (!confirm('Excluir este exemplo?')) return;
    try { await deleteExample(id); } catch { /* mutation hook reports failure */ }
  }
  if (isLoading) return <div className="flex justify-center p-8"><Loader2 className="h-8 w-8 animate-spin" /></div>;
  if (isError) return <div role="alert" className="space-y-3 p-4 border rounded-lg">
    <p>Não foi possível carregar os exemplos.</p><Button onClick={() => refetch()}>Tentar novamente</Button>
  </div>;
  return <div className="space-y-6">
    <div className="flex items-center justify-between gap-4">
      <h2 className="text-lg font-semibold">Few-Shot Examples</h2>
      <Button onClick={() => edit()}><Plus className="mr-2 h-4 w-4" />Novo exemplo</Button>
    </div>
    <p className="text-sm text-muted-foreground">Exemplos de interação usados pela Cloudinha, do mais recente para o mais antigo.</p>
    <div className="grid gap-3">{examples.map(example => <Card key={example.id}>
      <CardContent className="pt-4 space-y-2">
        <div className="flex justify-between gap-3">
          <p className="text-sm text-muted-foreground">{example.intent_category || 'Sem categoria'} · {example.is_active ? 'Ativo' : 'Inativo'}</p>
          <div className="flex gap-1">
            <Button variant="ghost" size="icon" aria-label="Editar exemplo" onClick={() => edit(example)}><Pencil className="h-4 w-4" /></Button>
            <Button variant="ghost" size="icon" aria-label="Excluir exemplo" onClick={() => remove(example.id)}><Trash2 className="h-4 w-4" /></Button>
          </div>
        </div>
        <p className="font-medium whitespace-pre-wrap">{example.input_query}</p>
        <p className="text-sm whitespace-pre-wrap">{example.ideal_output}</p>
        {example.reasoning && <p className="text-sm text-muted-foreground whitespace-pre-wrap">{example.reasoning}</p>}
      </CardContent>
    </Card>)}</div>
    {examples.length === 0 && <p className="p-8 border border-dashed rounded-lg text-muted-foreground">Nenhum exemplo cadastrado.</p>}
    <Dialog open={open} onOpenChange={setOpen}><DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
      <DialogHeader><DialogTitle>{editingId ? 'Editar exemplo' : 'Novo exemplo'}</DialogTitle></DialogHeader>
      <div className="space-y-4">
        <div className="space-y-2"><Label htmlFor="example-category">Categoria</Label><Input id="example-category" value={form.intent_category ?? ''} onChange={e => setForm({ ...form, intent_category: e.target.value })} /></div>
        <div className="space-y-2"><Label htmlFor="example-input">Mensagem do usuário</Label><Textarea id="example-input" rows={3} value={form.input_query} onChange={e => setForm({ ...form, input_query: e.target.value })} /></div>
        <div className="space-y-2"><Label htmlFor="example-output">Resposta esperada</Label><Textarea id="example-output" rows={6} value={form.ideal_output} onChange={e => setForm({ ...form, ideal_output: e.target.value })} /></div>
        <div className="space-y-2"><Label htmlFor="example-reasoning">Orientação do exemplo</Label><Textarea id="example-reasoning" rows={3} value={form.reasoning ?? ''} onChange={e => setForm({ ...form, reasoning: e.target.value })} /></div>
        <div className="flex items-center gap-2"><Switch id="example-active" checked={form.is_active === true} onCheckedChange={is_active => setForm({ ...form, is_active })} /><Label htmlFor="example-active">Ativo</Label></div>
      </div>
      <DialogFooter><Button variant="outline" onClick={() => setOpen(false)}>Cancelar</Button>
        <Button onClick={save} disabled={saving || !form.input_query.trim() || !form.ideal_output.trim()}>Salvar</Button>
      </DialogFooter>
    </DialogContent></Dialog>
  </div>;
}
