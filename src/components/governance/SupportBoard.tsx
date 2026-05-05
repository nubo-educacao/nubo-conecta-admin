import React, { useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { fetchSupportCards, updateCardStatus, deleteCard, type SnapsCard } from "@/services/snapsApiService";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { AlertCircle, Bug, Lightbulb, Loader2, Trash2, ChevronLeft, ChevronRight } from "lucide-react";
import { format } from "date-fns";
import { ptBR } from "date-fns/locale";
import { toast } from "@/hooks/use-toast";

const STATUS_CONFIG: Record<string, { label: string; className: string }> = {
  "new-issues": { label: "Novo",          className: "bg-red-500" },
  todo:         { label: "A Fazer",       className: "bg-slate-500" },
  in_progress:  { label: "Em Progresso",  className: "bg-blue-500" },
  review:       { label: "Em Review",     className: "bg-purple-500" },
  assurance:    { label: "Em Validação",  className: "bg-yellow-500 text-black" },
  done:         { label: "Concluído",     className: "bg-green-600" },
  backlog:      { label: "Backlog",       className: "bg-slate-400" },
};

const PRIORITY_CONFIG: Record<string, { label: string; className: string }> = {
  Critical: { label: "Crítico", className: "border-red-600 text-red-600" },
  High:     { label: "Alta",    className: "border-orange-500 text-orange-500" },
  Medium:   { label: "Média",   className: "border-yellow-500 text-yellow-600" },
  Low:      { label: "Baixa",   className: "border-slate-400 text-slate-500" },
};

const STATUS_OPTIONS = Object.entries(STATUS_CONFIG).map(([value, { label }]) => ({ value, label }));

function statusCfg(status: string) {
  return STATUS_CONFIG[status] ?? { label: status, className: "bg-slate-500" };
}

function priorityCfg(priority?: string) {
  return PRIORITY_CONFIG[priority ?? "Medium"] ?? PRIORITY_CONFIG["Medium"];
}

// ── Card Detail Modal ──────────────────────────────────────────────────────────
function CardDetailModal({
  card,
  open,
  onClose,
}: {
  card: SnapsCard;
  open: boolean;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const [selectedStatus, setSelectedStatus] = useState(card.status);

  const mutation = useMutation({
    mutationFn: () => updateCardStatus(card.id, selectedStatus),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["snaps-support-cards"] });
      toast({ title: "Status atualizado", description: `Card movido para "${statusCfg(selectedStatus).label}".` });
      onClose();
    },
    onError: (err: Error) => {
      toast({ title: "Erro ao atualizar", description: err.message, variant: "destructive" });
    },
  });

  const deleteMutation = useMutation({
    mutationFn: () => deleteCard(card.id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["snaps-support-cards"] });
      toast({ title: "Card excluído", description: "O card foi removido com sucesso." });
      onClose();
    },
    onError: (err: Error) => {
      toast({ title: "Erro ao excluir", description: err.message, variant: "destructive" });
    },
  });

  const isBug = card.card_type === "bug";
  const pcfg = priorityCfg(card.priority);
  const scfg = statusCfg(card.status);
  const hasChanged = selectedStatus !== card.status;

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <div className="flex items-center gap-2 mb-1">
            {isBug
              ? <Bug className="h-5 w-5 text-red-500" />
              : <Lightbulb className="h-5 w-5 text-green-500" />
            }
            <span className="text-xs text-muted-foreground uppercase tracking-wide">
              {isBug ? "Bug Report" : "Feature Request"}
            </span>
          </div>
          <DialogTitle className="text-base leading-snug">{card.title}</DialogTitle>
          <div className="flex gap-2 mt-2 flex-wrap">
            <Badge variant="outline" className={`text-xs ${pcfg.className}`}>{pcfg.label}</Badge>
            <Badge className={`text-xs ${scfg.className}`}>{scfg.label}</Badge>
          </div>
        </DialogHeader>

        {card.description && (
          <div className="text-sm text-foreground/80 mt-2 max-h-[40vh] overflow-y-auto pr-2 prose prose-sm dark:prose-invert max-w-none prose-p:leading-snug prose-headings:text-sm prose-headings:font-semibold prose-headings:mb-1 prose-a:text-blue-500 hover:prose-a:text-blue-600 prose-img:rounded-md prose-img:border prose-img:max-h-64 prose-img:w-auto prose-img:object-contain">
            <ReactMarkdown remarkPlugins={[remarkGfm]}>
              {card.description}
            </ReactMarkdown>
          </div>
        )}

        {card.created_at && (
          <p className="text-xs text-muted-foreground mt-1">
            Criado em {format(new Date(card.created_at), "dd/MM/yyyy 'às' HH:mm", { locale: ptBR })}
          </p>
        )}

        {/* Status changer */}
        <div className="border-t pt-4 mt-2 space-y-3">
          <label className="text-sm font-medium">Alterar status</label>
          <Select value={selectedStatus} onValueChange={setSelectedStatus}>
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {STATUS_OPTIONS.map(({ value, label }) => (
                <SelectItem key={value} value={value}>{label}</SelectItem>
              ))}
            </SelectContent>
          </Select>

          <div className="flex gap-2">
            <Button
              className="flex-1"
              disabled={!hasChanged || mutation.isPending}
              onClick={() => mutation.mutate()}
            >
              {mutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              {hasChanged ? "Salvar status" : "Sem alterações"}
            </Button>
            <Button
              variant="destructive"
              size="icon"
              disabled={deleteMutation.isPending}
              onClick={() => {
                if (confirm("Tem certeza que deseja excluir este card? Esta ação não pode ser desfeita.")) {
                  deleteMutation.mutate();
                }
              }}
            >
              {deleteMutation.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

// ── SupportBoard ───────────────────────────────────────────────────────────────
export function SupportBoard() {
  const [selected, setSelected] = useState<SnapsCard | null>(null);

  return (
    <div className="space-y-12 pb-10">
      <section>
        <div className="flex items-center gap-2 mb-4">
          <div className="h-2 w-2 rounded-full bg-blue-500 animate-pulse" />
          <h2 className="text-lg font-semibold tracking-tight">Chamados Ativos</h2>
        </div>
        <SupportSection 
          excludeStatus="done" 
          onSelect={setSelected} 
          queryKey="active"
        />
      </section>
      
      <section className="border-t pt-8">
        <div className="flex items-center gap-2 mb-4">
          <div className="h-2 w-2 rounded-full bg-muted-foreground/40" />
          <h2 className="text-lg font-semibold tracking-tight text-muted-foreground">Histórico de Concluídos</h2>
        </div>
        <SupportSection 
          status="done" 
          onSelect={setSelected} 
          queryKey="done"
        />
      </section>

      {selected && (
        <CardDetailModal
          card={selected}
          open={!!selected}
          onClose={() => setSelected(null)}
        />
      )}
    </div>
  );
}

interface SupportSectionProps {
  status?: string;
  excludeStatus?: string;
  onSelect: (card: SnapsCard) => void;
  queryKey: string;
}

function SupportSection({ status, excludeStatus, onSelect, queryKey }: SupportSectionProps) {
  const [page, setPage] = useState(0);
  const limit = 10;

  const { data: response, isLoading, isError, error } = useQuery({
    queryKey: ["snaps-support-cards", queryKey, page],
    queryFn: () => fetchSupportCards(status, limit, page * limit, excludeStatus),
  });

  const cards = response?.items || [];
  const total = response?.total || 0;
  const totalPages = Math.ceil(total / limit);

  if (isLoading) {
    return (
      <div className="space-y-3">
        <Skeleton className="h-14 w-full" />
        <Skeleton className="h-14 w-full" />
        <Skeleton className="h-14 w-full" />
      </div>
    );
  }

  if (isError) {
    return (
      <div className="flex flex-col items-center gap-2 py-10 text-red-500">
        <AlertCircle className="h-8 w-8" />
        <p className="text-sm">{(error as Error).message}</p>
      </div>
    );
  }

  if (!cards || cards.length === 0) {
    return (
      <div className="py-10 text-center text-muted-foreground text-sm border rounded-md border-dashed">
        Nenhum chamado encontrado nesta categoria.
      </div>
    );
  }

  return (
    <>
      <div className="divide-y rounded-md border overflow-hidden">
        {cards.map((card) => {
          const cfg = statusCfg(card.status);
          const pcfg = priorityCfg(card.priority);
          const isBug = card.card_type === "bug";
          return (
            <div
              key={card.id}
              className="flex items-center justify-between p-4 hover:bg-muted/50 transition-colors cursor-pointer"
              onClick={() => onSelect(card)}
            >
              <div className="flex items-center gap-3 min-w-0">
                <div className={`p-2 rounded-full ${isBug ? 'bg-red-50 text-red-500' : 'bg-green-50 text-green-500'}`}>
                  {isBug ? <Bug className="h-4 w-4" /> : <Lightbulb className="h-4 w-4" />}
                </div>
                <div className="min-w-0">
                  <p className="text-sm font-medium truncate">{card.title}</p>
                  {card.created_at && (
                    <p className="text-xs text-muted-foreground">
                      Criado em {format(new Date(card.created_at), "dd/MM/yyyy HH:mm", { locale: ptBR })}
                    </p>
                  )}
                </div>
              </div>
              <div className="flex items-center gap-2 shrink-0 ml-4">
                <Badge variant="outline" className={`text-[10px] uppercase font-bold px-2 ${pcfg.className}`}>
                  {pcfg.label}
                </Badge>
                <Badge variant="secondary" className={`text-[10px] uppercase font-bold px-2 ${cfg.className}`}>
                  {cfg.label}
                </Badge>
              </div>
            </div>
          );
        })}
      </div>

      {totalPages > 1 && (
        <div className="flex items-center justify-between mt-4 px-1">
          <p className="text-xs text-muted-foreground">
            Mostrando {page * limit + 1} - {Math.min((page + 1) * limit, total)} de {total}
          </p>
          <div className="flex items-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              disabled={page === 0}
              onClick={() => setPage(p => p - 1)}
              className="h-8"
            >
              <ChevronLeft className="h-4 w-4 mr-1" />
              Anterior
            </Button>
            <div className="flex items-center gap-1">
              <span className="text-xs font-semibold tabular-nums">{page + 1}</span>
              <span className="text-xs text-muted-foreground">/</span>
              <span className="text-xs text-muted-foreground tabular-nums">{totalPages}</span>
            </div>
            <Button
              variant="ghost"
              size="sm"
              disabled={page >= totalPages - 1}
              onClick={() => setPage(p => p + 1)}
              className="h-8"
            >
              Próximo
              <ChevronRight className="h-4 w-4 ml-1" />
            </Button>
          </div>
        </div>
      )}
    </>
  );
}
