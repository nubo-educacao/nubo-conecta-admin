import { useState, useEffect } from "react";
import { Plus, GripVertical, Pencil, Trash2, RefreshCw, Save } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from "@/components/ui/dialog";
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select";
import { useToast } from "@/hooks/use-toast";
import { supabase } from "@/integrations/supabase/client";

// ─── Tipos ───────────────────────────────────────────────────────────────────

interface HomeSection {
  id: string;
  title: string;
  section_type: string;
  data_source: string;
  display_order: number;
  is_active: boolean;
  target_states: string[] | null;
  target_onboarding_status: string | null;
  config: Record<string, unknown>;
}

const SECTION_TYPES = [
  { value: "opportunity_carousel", label: "Carrossel de Oportunidades" },
  { value: "institution_carousel", label: "Carrossel de Instituições" },
  { value: "match_carousel", label: "Carrossel Para Você (Match)" },
  { value: "dates", label: "Datas Importantes" },
  { value: "hero_search", label: "Hero Buscador" },
  { value: "dynamic_cta", label: "CTA Dinâmico" },
];

const DATA_SOURCES = [
  { value: "partner_opportunities", label: "Oportunidades Parceiras" },
  { value: "recent_opportunities", label: "Oportunidades Recentes" },
  { value: "match_results", label: "Resultados de Match" },
  { value: "institutions", label: "Instituições Parceiras" },
  { value: "important_dates", label: "Datas do Calendário" },
  { value: "static", label: "Estático (sem dados)" },
];

const ESTADOS_BR = [
  "AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA",
  "MT", "MS", "MG", "PA", "PB", "PR", "PE", "PI", "RJ", "RN",
  "RS", "RO", "RR", "SC", "SP", "SE", "TO",
];

// ─── Page Component ──────────────────────────────────────────────────────────

export default function AppCMS() {
  const [sections, setSections] = useState<HomeSection[]>([]);
  const [loading, setLoading] = useState(true);
  const [editingSection, setEditingSection] = useState<HomeSection | null>(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  const { toast } = useToast();

  const fetchSections = async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from("home_sections")
      .select("*")
      .order("display_order", { ascending: true });

    if (error) {
      toast({ title: "Erro", description: error.message, variant: "destructive" });
    } else {
      setSections((data ?? []) as HomeSection[]);
    }
    setLoading(false);
  };

  useEffect(() => { fetchSections(); }, []);

  const toggleActive = async (section: HomeSection) => {
    const { error } = await supabase
      .from("home_sections")
      .update({ is_active: !section.is_active, updated_at: new Date().toISOString() })
      .eq("id", section.id);

    if (error) {
      toast({ title: "Erro", description: error.message, variant: "destructive" });
    } else {
      setSections((prev) =>
        prev.map((s) => (s.id === section.id ? { ...s, is_active: !s.is_active } : s))
      );
    }
  };

  const deleteSection = async (id: string) => {
    if (!confirm("Tem certeza que deseja excluir esta seção?")) return;
    const { error } = await supabase.from("home_sections").delete().eq("id", id);
    if (error) {
      toast({ title: "Erro", description: error.message, variant: "destructive" });
    } else {
      setSections((prev) => prev.filter((s) => s.id !== id));
      toast({ title: "Seção excluída" });
    }
  };

  const handleEdit = (section: HomeSection) => {
    setEditingSection({ ...section });
    setDialogOpen(true);
  };

  const handleNew = () => {
    setEditingSection({
      id: "",
      title: "",
      section_type: "opportunity_carousel",
      data_source: "partner_opportunities",
      display_order: sections.length,
      is_active: true,
      target_states: null,
      target_onboarding_status: null,
      config: {},
    });
    setDialogOpen(true);
  };

  const handleSave = async () => {
    if (!editingSection) return;

    if (editingSection.id) {
      // UPDATE
      const { error } = await supabase
        .from("home_sections")
        .update({
          title: editingSection.title,
          section_type: editingSection.section_type,
          data_source: editingSection.data_source,
          display_order: editingSection.display_order,
          target_states: editingSection.target_states,
          config: editingSection.config,
          updated_at: new Date().toISOString(),
        })
        .eq("id", editingSection.id);

      if (error) {
        toast({ title: "Erro", description: error.message, variant: "destructive" });
        return;
      }
    } else {
      // INSERT
      const { error } = await supabase.from("home_sections").insert({
        title: editingSection.title,
        section_type: editingSection.section_type,
        data_source: editingSection.data_source,
        display_order: editingSection.display_order,
        target_states: editingSection.target_states,
        config: editingSection.config,
      });

      if (error) {
        toast({ title: "Erro", description: error.message, variant: "destructive" });
        return;
      }
    }

    setDialogOpen(false);
    setEditingSection(null);
    fetchSections();
    toast({ title: "Seção salva com sucesso" });
  };

  return (
    <div className="flex-1 space-y-6 p-8 pt-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-3xl font-bold tracking-tight">CMS da Home</h2>
          <p className="text-muted-foreground">
            Configure as seções e carrosséis exibidos na tela inicial do App.
          </p>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={fetchSections}>
            <RefreshCw className="h-4 w-4 mr-2" />
            Atualizar
          </Button>
          <Button size="sm" onClick={handleNew}>
            <Plus className="h-4 w-4 mr-2" />
            Nova Seção
          </Button>
        </div>
      </div>

      {/* Lista de Seções */}
      {loading ? (
        <div className="space-y-3">
          {[...Array(5)].map((_, i) => <Skeleton key={i} className="h-20" />)}
        </div>
      ) : (
        <div className="space-y-3">
          {sections.map((section) => (
            <div
              key={section.id}
              className={`flex items-center gap-4 rounded-lg border p-4 transition-all ${
                section.is_active ? "bg-card" : "bg-muted/30 opacity-60"
              }`}
            >
              <div className="text-muted-foreground cursor-grab">
                <GripVertical className="h-5 w-5" />
              </div>

              <div className="text-sm font-mono text-muted-foreground w-8 text-center">
                {section.display_order}
              </div>

              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 mb-1">
                  <span className="font-semibold">{section.title || "(sem título)"}</span>
                  <Badge variant="outline" className="text-xs">
                    {SECTION_TYPES.find((t) => t.value === section.section_type)?.label ?? section.section_type}
                  </Badge>
                </div>
                <div className="flex items-center gap-2 text-xs text-muted-foreground">
                  <span>Fonte: {DATA_SOURCES.find((d) => d.value === section.data_source)?.label ?? section.data_source}</span>
                  {section.target_states && section.target_states.length > 0 && (
                    <Badge variant="secondary" className="text-[10px]">
                      {section.target_states.join(", ")}
                    </Badge>
                  )}
                </div>
              </div>

              <Switch
                checked={section.is_active}
                onCheckedChange={() => toggleActive(section)}
                aria-label={section.is_active ? "Desativar" : "Ativar"}
              />

              <Button variant="ghost" size="icon" onClick={() => handleEdit(section)}>
                <Pencil className="h-4 w-4" />
              </Button>

              <Button variant="ghost" size="icon" onClick={() => deleteSection(section.id)}>
                <Trash2 className="h-4 w-4 text-destructive" />
              </Button>
            </div>
          ))}
        </div>
      )}

      {/* Modal Criação/Edição */}
      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>{editingSection?.id ? "Editar Seção" : "Nova Seção"}</DialogTitle>
          </DialogHeader>

          {editingSection && (
            <div className="space-y-4 py-2">
              <div>
                <Label>Título</Label>
                <Input
                  value={editingSection.title}
                  onChange={(e) => setEditingSection({ ...editingSection, title: e.target.value })}
                  placeholder="ex: Oportunidades para São Paulo"
                />
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <Label>Tipo de Seção</Label>
                  <Select
                    value={editingSection.section_type}
                    onValueChange={(v) => setEditingSection({ ...editingSection, section_type: v })}
                  >
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {SECTION_TYPES.map((t) => (
                        <SelectItem key={t.value} value={t.value}>{t.label}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                <div>
                  <Label>Fonte de Dados</Label>
                  <Select
                    value={editingSection.data_source}
                    onValueChange={(v) => setEditingSection({ ...editingSection, data_source: v })}
                  >
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {DATA_SOURCES.map((d) => (
                        <SelectItem key={d.value} value={d.value}>{d.label}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>

              <div>
                <Label>Ordem de Exibição</Label>
                <Input
                  type="number"
                  value={editingSection.display_order}
                  onChange={(e) => setEditingSection({ ...editingSection, display_order: parseInt(e.target.value) || 0 })}
                />
              </div>

              <div>
                <Label>Filtro por Estado (opcional)</Label>
                <p className="text-xs text-muted-foreground mb-2">
                  Se preenchido, esta seção só aparecerá para usuários dos estados selecionados.
                </p>
                <div className="flex flex-wrap gap-1.5 max-h-32 overflow-y-auto p-2 border rounded-lg">
                  {ESTADOS_BR.map((estado) => {
                    const selected = editingSection.target_states?.includes(estado) ?? false;
                    return (
                      <Badge
                        key={estado}
                        variant={selected ? "default" : "outline"}
                        className="cursor-pointer text-xs"
                        onClick={() => {
                          const current = editingSection.target_states ?? [];
                          const next = selected
                            ? current.filter((s) => s !== estado)
                            : [...current, estado];
                          setEditingSection({
                            ...editingSection,
                            target_states: next.length > 0 ? next : null,
                          });
                        }}
                      >
                        {estado}
                      </Badge>
                    );
                  })}
                </div>
              </div>

              <div>
                <Label>Link "Ver Todos" (see_all_href)</Label>
                <Input
                  value={(editingSection.config as { see_all_href?: string }).see_all_href ?? ""}
                  onChange={(e) =>
                    setEditingSection({
                      ...editingSection,
                      config: { ...editingSection.config, see_all_href: e.target.value || undefined },
                    })
                  }
                  placeholder="/oportunidades"
                />
              </div>
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setDialogOpen(false)}>Cancelar</Button>
            <Button onClick={handleSave}>
              <Save className="h-4 w-4 mr-2" />
              Salvar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
