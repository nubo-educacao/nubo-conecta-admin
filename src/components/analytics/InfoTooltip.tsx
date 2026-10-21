import { useState, type MouseEvent, type KeyboardEvent } from "react";
import * as TooltipPrimitive from "@radix-ui/react-tooltip";
import { HelpCircle } from "lucide-react";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";

interface InfoTooltipProps {
  /** Nome da métrica, para o rótulo acessível do ícone. */
  label: string;
  children: string;
}

// Ícone "?" dos big numbers. O conteúdo vai para um portal no body: os cards
// têm overflow-hidden e recortavam o texto. Clique/toque também abre, porque o
// Radix não abre tooltip por toque (mobile). Abre em vez de alternar: o toque já
// foca o gatilho (o Radix abre no foco) e um toggle fecharia em seguida. Fecha
// com Esc, toque/clique fora, perda de foco ou ao tirar o mouse.
export function InfoTooltip({ label, children }: InfoTooltipProps) {
  const [open, setOpen] = useState(false);

  // Pode estar dentro de um card clicável (Power Users): não abre o drill-down.
  const show = (e: MouseEvent | KeyboardEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setOpen(true);
  };

  return (
    <TooltipProvider>
      <Tooltip open={open} onOpenChange={setOpen} delayDuration={200}>
        <TooltipTrigger asChild>
          <span
            role="button"
            tabIndex={0}
            aria-label={`Sobre ${label}`}
            onClick={show}
            onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && show(e)}
            // No toque o pointerleave vem logo após o pointerup e o Radix fecharia o tooltip recém-aberto.
            onPointerLeave={(e) => e.pointerType === "touch" && e.preventDefault()}
            className="inline-flex text-muted-foreground/60 hover:text-muted-foreground transition-colors cursor-help"
          >
            <HelpCircle className="h-3.5 w-3.5" />
          </span>
        </TooltipTrigger>
        <TooltipPrimitive.Portal>
          <TooltipContent side="bottom" collisionPadding={16} className="max-w-[min(20rem,calc(100vw-2rem))]">
            <p className="text-xs">{children}</p>
          </TooltipContent>
        </TooltipPrimitive.Portal>
      </Tooltip>
    </TooltipProvider>
  );
}
