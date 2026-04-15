import { useState, useEffect } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Switch } from '@/components/ui/switch';
import { Textarea } from '@/components/ui/textarea';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog';
import { supabase } from '@/integrations/supabase/client';
import { toast } from 'sonner';
import { Pencil, Plus, Loader2 } from 'lucide-react';

interface SystemIntent {
  id: string;
  command: string;
  trigger_route: string | null;
  trigger_type: string;
  open_drawer: boolean;
  delay_ms: number;
  trigger_message: string | null;
  description: string | null;
  is_active: boolean;
}

const TRIGGER_TYPE_LABELS: Record<string, string> = {
  route_change: 'Mudança de rota',
  manual: 'Manual',
  timer: 'Timer',
};

function IntentEditDialog({
  intent,
  onSaved,
}: {
  intent: SystemIntent;
  onSaved: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({
    trigger_route: intent.trigger_route ?? '',
    trigger_message: intent.trigger_message ?? '',
    open_drawer: intent.open_drawer,
    delay_ms: intent.delay_ms,
    description: intent.description ?? '',
  });

  async function handleSave() {
    setSaving(true);
    try {
      const { error } = await supabase
        .from('system_intents')
        .update({
          trigger_route: form.trigger_route || null,
          trigger_message: form.trigger_message || null,
          open_drawer: form.open_drawer,
          delay_ms: form.delay_ms,
          description: form.description || null,
          updated_at: new Date().toISOString(),
        })
        .eq('id', intent.id);

      if (error) throw error;
      toast.success('Intent atualizado!');
      setOpen(false);
      onSaved();
    } catch (e: any) {
      toast.error(`Erro ao salvar: ${e.message}`);
    } finally {
      setSaving(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="icon" className="h-7 w-7">
          <Pencil className="h-3.5 w-3.5" />
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Editar <code className="text-primary">{intent.command}</code></DialogTitle>
          <DialogDescription>
            Configure o trigger e o comportamento deste system intent.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="space-y-1.5">
            <Label htmlFor="trigger_route">Trigger Route (regex)</Label>
            <Input
              id="trigger_route"
              placeholder="ex: ^/oportunidades/.+$"
              value={form.trigger_route}
              onChange={(e) => setForm((f) => ({ ...f, trigger_route: e.target.value }))}
              className="font-mono text-sm"
            />
            <p className="text-xs text-muted-foreground">
              Regex da rota que dispara este intent. Deixe vazio para intents manuais.
            </p>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="trigger_message">Mensagem de Trigger</Label>
            <Textarea
              id="trigger_message"
              placeholder="ex: O usuário está vendo {{title}} em {{institution}}. Ofereça ajuda contextual."
              value={form.trigger_message}
              onChange={(e) => setForm((f) => ({ ...f, trigger_message: e.target.value }))}
              rows={4}
              className="text-sm"
            />
            <p className="text-xs text-muted-foreground">
              Mensagem invisível enviada ao pipeline LLM. Placeholders: <code>{'{{title}}'}</code>, <code>{'{{institution}}'}</code>, <code>{'{{route}}'}</code>.
            </p>
          </div>

          <div className="flex items-center gap-6">
            <div className="flex items-center gap-2">
              <Switch
                id="open_drawer"
                checked={form.open_drawer}
                onCheckedChange={(v) => setForm((f) => ({ ...f, open_drawer: v }))}
              />
              <Label htmlFor="open_drawer">Abrir drawer automaticamente</Label>
            </div>

            {form.open_drawer && (
              <div className="flex items-center gap-2">
                <Label htmlFor="delay_ms" className="whitespace-nowrap">Delay (ms)</Label>
                <Input
                  id="delay_ms"
                  type="number"
                  min={0}
                  step={500}
                  value={form.delay_ms}
                  onChange={(e) => setForm((f) => ({ ...f, delay_ms: Number(e.target.value) }))}
                  className="w-24"
                />
              </div>
            )}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="description">Descrição</Label>
            <Input
              id="description"
              value={form.description}
              onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
              placeholder="Descrição para o backoffice"
            />
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)}>Cancelar</Button>
          <Button onClick={handleSave} disabled={saving}>
            {saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            Salvar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export default function SystemIntentsManager() {
  const [intents, setIntents] = useState<SystemIntent[]>([]);
  const [loading, setLoading] = useState(true);

  async function loadIntents() {
    setLoading(true);
    try {
      const { data, error } = await supabase
        .from('system_intents')
        .select('*')
        .order('trigger_type')
        .order('command');
      if (error) throw error;
      setIntents(data ?? []);
    } catch (e: any) {
      toast.error(`Erro ao carregar intents: ${e.message}`);
    } finally {
      setLoading(false);
    }
  }

  async function toggleActive(intent: SystemIntent) {
    try {
      const { error } = await supabase
        .from('system_intents')
        .update({ is_active: !intent.is_active, updated_at: new Date().toISOString() })
        .eq('id', intent.id);
      if (error) throw error;
      toast.success(`Intent ${intent.is_active ? 'desativado' : 'ativado'}.`);
      loadIntents();
    } catch (e: any) {
      toast.error(`Erro: ${e.message}`);
    }
  }

  useEffect(() => {
    loadIntents();
  }, []);

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-lg font-semibold">System Intents</h3>
          <p className="text-sm text-muted-foreground">
            Comandos que disparam reações da Cloudinha. A mensagem de trigger é enviada invisível ao pipeline LLM — a Cloudinha gera uma resposta real.
          </p>
        </div>
      </div>

      {loading ? (
        <div className="flex items-center justify-center py-10">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </div>
      ) : (
        <div className="space-y-3">
          {intents.map((intent) => (
            <div
              key={intent.id}
              className="flex items-start gap-4 rounded-lg border bg-card p-4"
            >
              <Switch
                checked={intent.is_active}
                onCheckedChange={() => toggleActive(intent)}
                aria-label={`Toggle ${intent.command}`}
              />

              <div className="flex-1 min-w-0 space-y-1">
                <div className="flex items-center gap-2 flex-wrap">
                  <p className="font-mono text-sm font-semibold">{intent.command}</p>
                  <Badge variant="outline" className="text-xs">
                    {TRIGGER_TYPE_LABELS[intent.trigger_type] ?? intent.trigger_type}
                  </Badge>
                  {intent.open_drawer && (
                    <Badge variant="secondary" className="text-xs">
                      Abre drawer ({intent.delay_ms}ms)
                    </Badge>
                  )}
                  {!intent.is_active && (
                    <Badge variant="secondary" className="text-xs opacity-60">Inativo</Badge>
                  )}
                </div>

                {intent.description && (
                  <p className="text-sm text-muted-foreground">{intent.description}</p>
                )}

                {intent.trigger_route && (
                  <p className="text-xs text-muted-foreground font-mono">
                    <span className="font-medium text-foreground">Route:</span> {intent.trigger_route}
                  </p>
                )}

                {intent.trigger_message && (
                  <p className="text-xs text-muted-foreground line-clamp-2">
                    <span className="font-medium text-foreground">Trigger:</span> {intent.trigger_message}
                  </p>
                )}
              </div>

              <IntentEditDialog intent={intent} onSaved={loadIntents} />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
