import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetDescription,
} from "@/components/ui/sheet";
import { Badge } from "@/components/ui/badge";
import { Clock, Cpu, DollarSign, Zap } from "lucide-react";
import type { AgentTurnRow } from "@/lib/telemetry-queries";

interface TurnDrillDownProps {
  turn: AgentTurnRow | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export default function TurnDrillDown({ turn, open, onOpenChange }: TurnDrillDownProps) {
  if (!turn) return null;

  const sections = [
    {
      label: "Planning Output",
      content: turn.planning_output,
      latency: turn.planning_latency_ms,
      color: "text-violet-600",
      bgColor: "bg-violet-50 border-violet-200",
    },
    {
      label: "Reasoning Report",
      content: turn.reasoning_output ?? turn.reasoning_report,
      latency: turn.reasoning_latency_ms,
      color: "text-amber-600",
      bgColor: "bg-amber-50 border-amber-200",
    },
    {
      label: "Response Output",
      content: turn.response_output,
      latency: turn.response_latency_ms,
      color: "text-emerald-600",
      bgColor: "bg-emerald-50 border-emerald-200",
    },
  ];

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-full sm:max-w-xl overflow-y-auto">
        <SheetHeader>
          <SheetTitle className="flex items-center gap-2">
            <Cpu className="h-5 w-5" />
            Turno Cognitivo
          </SheetTitle>
          <SheetDescription>
            {new Date(turn.created_at).toLocaleString("pt-BR")} · Sessão{" "}
            <code className="text-xs">{turn.session_id?.slice(0, 12)}...</code>
          </SheetDescription>
        </SheetHeader>

        <div className="mt-6 space-y-4">
          {/* KPI Row */}
          <div className="grid grid-cols-3 gap-3">
            <div className="rounded-lg border bg-card p-3 text-center">
              <Clock className="h-4 w-4 mx-auto mb-1 text-muted-foreground" />
              <p className="text-lg font-bold">{turn.total_latency_ms ?? 0}ms</p>
              <p className="text-xs text-muted-foreground">Latência Total</p>
            </div>
            <div className="rounded-lg border bg-card p-3 text-center">
              <Zap className="h-4 w-4 mx-auto mb-1 text-muted-foreground" />
              <p className="text-lg font-bold">
                {((turn.input_tokens ?? 0) + (turn.output_tokens ?? 0)).toLocaleString()}
              </p>
              <p className="text-xs text-muted-foreground">Tokens</p>
            </div>
            <div className="rounded-lg border bg-card p-3 text-center">
              <DollarSign className="h-4 w-4 mx-auto mb-1 text-muted-foreground" />
              <p className="text-lg font-bold">
                ${turn.estimated_cost_usd?.toFixed(4) ?? "—"}
              </p>
              <p className="text-xs text-muted-foreground">Custo</p>
            </div>
          </div>

          {/* Intent Badge */}
          <div className="flex items-center gap-2">
            <span className="text-sm text-muted-foreground">Categoria:</span>
            <Badge variant="outline">{turn.intent_category ?? "—"}</Badge>
            <Badge variant="secondary">{turn.action ?? "none"}</Badge>
          </div>

          {/* Tools Used */}
          {turn.tools_used && (turn.tools_used as unknown[]).length > 0 && (
            <div>
              <p className="text-sm font-semibold mb-2">Tools Chamadas:</p>
              <div className="flex flex-wrap gap-1.5">
                {(turn.tools_used as Array<{ name: string }>).map((t, i) => (
                  <Badge key={i} variant="outline" className="font-mono text-xs">
                    {t.name}
                  </Badge>
                ))}
              </div>
            </div>
          )}

          {/* Phase Outputs */}
          {sections.map((section) => (
            <div key={section.label}>
              <div className="flex items-center justify-between mb-1.5">
                <p className={`text-sm font-semibold ${section.color}`}>{section.label}</p>
                {section.latency != null && (
                  <span className="text-xs text-muted-foreground">{section.latency}ms</span>
                )}
              </div>
              <div
                className={`rounded-lg border p-3 text-sm font-mono whitespace-pre-wrap max-h-60 overflow-y-auto ${section.bgColor}`}
              >
                {section.content || (
                  <span className="text-muted-foreground italic">Sem dados</span>
                )}
              </div>
            </div>
          ))}
        </div>
      </SheetContent>
    </Sheet>
  );
}
