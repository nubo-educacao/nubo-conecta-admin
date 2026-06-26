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

  const steps = turn.steps ?? [];

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-full sm:max-w-xl overflow-y-auto">
        <SheetHeader>
          <SheetTitle className="flex items-center gap-2">
            <Cpu className="h-5 w-5" />
            Turno Cognitivo (ReAct)
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

          {/* Model & Tools Latency Breakdown */}
          <div className="grid grid-cols-2 gap-3">
            <div className="rounded-lg border bg-card p-2 text-center text-xs">
              <p className="font-semibold">{turn.model_latency_ms ?? "—"} ms</p>
              <p className="text-[10px] text-muted-foreground">Latência Model (LLM)</p>
            </div>
            <div className="rounded-lg border bg-card p-2 text-center text-xs">
              <p className="font-semibold">{turn.tools_latency_ms ?? "—"} ms</p>
              <p className="text-[10px] text-muted-foreground">Latência Tools</p>
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

          {/* ReAct Steps */}
          <div className="space-y-4 pt-2 border-t">
            <p className="text-sm font-semibold">Execução do Loop ReAct:</p>
            {steps.length === 0 ? (
              <p className="text-xs text-muted-foreground italic">Nenhum step intermediário registrado.</p>
            ) : (
              steps.map((step, i) => (
                <div key={i} className="space-y-2 border-l-2 border-primary/20 pl-3">
                  <h4 className="text-xs font-semibold text-slate-700">Step {i + 1}</h4>
                  {step.thought && (
                    <div className="bg-violet-50/50 rounded p-2.5 border border-violet-100">
                      <span className="text-[10px] font-bold text-violet-600 uppercase tracking-wider">Thought</span>
                      <pre className="text-xs font-mono whitespace-pre-wrap mt-1 text-slate-700">{step.thought}</pre>
                    </div>
                  )}
                  {step.action && (
                    <div className="bg-amber-50/50 rounded p-2.5 border border-amber-100">
                      <span className="text-[10px] font-bold text-amber-600 uppercase tracking-wider">Action: {step.action.tool}</span>
                      <pre className="text-xs font-mono whitespace-pre-wrap mt-1 text-slate-700">{JSON.stringify(step.action.args, null, 2)}</pre>
                    </div>
                  )}
                  {step.observation && (
                    <div className="bg-emerald-50/50 rounded p-2.5 border border-emerald-100">
                      <span className="text-[10px] font-bold text-emerald-600 uppercase tracking-wider">Observation</span>
                      <pre className="text-xs font-mono whitespace-pre-wrap mt-1 text-slate-700 max-h-48 overflow-y-auto">{step.observation}</pre>
                    </div>
                  )}
                </div>
              ))
            )}
          </div>

          {/* Final Agent Response */}
          <div className="bg-blue-50/50 rounded p-3 border border-blue-100 mt-4">
            <span className="text-[10px] font-bold text-blue-600 uppercase tracking-wider">Agent Output (Resposta Final)</span>
            <pre className="text-xs font-mono whitespace-pre-wrap mt-1 text-slate-700">{turn.agent_output ?? "Sem dados"}</pre>
          </div>
        </div>
      </SheetContent>
    </Sheet>
  );
}
