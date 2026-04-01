import { Users, MessageSquare, HelpCircle } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { InactiveUsersExportButton } from "./InactiveUsersExportButton";

interface TotalUsersCardProps {
  totalRegistered: number;
  activeUsers: number;
  activeWithMessages: number;
  catalogUsers: number;
  activeChange?: number;
}

export function TotalUsersCard({
  totalRegistered,
  activeUsers,
  activeWithMessages,
  catalogUsers,
  activeChange,
}: TotalUsersCardProps) {
  const inactiveUsers = totalRegistered - activeUsers;

  return (
    <div className="stat-card relative overflow-hidden border-t-4 border-t-primary col-span-2 lg:col-span-1">
      <div className="flex items-start justify-between">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-1 mb-1">
            <h3 className="text-sm font-medium text-muted-foreground truncate">
              Usuários Cadastrados
            </h3>
            <TooltipProvider>
              <Tooltip delayDuration={200}>
                <TooltipTrigger asChild>
                  <button className="text-muted-foreground/60 hover:text-muted-foreground transition-colors">
                    <HelpCircle className="h-3.5 w-3.5" />
                  </button>
                </TooltipTrigger>
                <TooltipContent 
                  side="top" 
                  className="max-w-xs bg-popover text-popover-foreground border-border"
                >
                  <p className="text-xs">
                    Total de usuários autenticados na plataforma (auth.users). 
                    Inclui todos que criaram conta, mesmo sem perfil completo.
                  </p>
                </TooltipContent>
              </Tooltip>
            </TooltipProvider>
          </div>
          <p className="text-3xl font-bold font-display">
            {totalRegistered.toLocaleString()}
          </p>
        </div>
        <div className="rounded-xl bg-primary/10 p-3">
          <Users className="h-5 w-5 text-primary" />
        </div>
      </div>
      
      {/* Summary breakdown */}
      <div className="mt-4 pt-3 border-t border-border/50 space-y-2">
        <div className="flex items-center justify-between text-xs">
          <div className="flex items-center gap-1.5">
            <div className="h-2 w-2 rounded-full bg-success" />
            <span className="text-muted-foreground">Ativos (7d):</span>
          </div>
          <div className="flex items-center gap-2">
            <span className="font-semibold text-success">{activeUsers.toLocaleString()}</span>
            {activeChange !== undefined && (
              <span className={cn(
                "text-[10px]",
                activeChange > 0 ? "text-success" : activeChange < 0 ? "text-destructive" : "text-muted-foreground"
              )}>
                {activeChange > 0 ? "+" : ""}{activeChange}%
              </span>
            )}
          </div>
        </div>
        <div className="flex items-center justify-between text-xs">
          <div className="flex items-center gap-1.5">
            <MessageSquare className="h-3 w-3 text-primary" />
            <span className="text-muted-foreground">Com mensagens:</span>
          </div>
          <span className="font-medium text-primary">{activeWithMessages.toLocaleString()}</span>
        </div>
        <div className="flex items-center justify-between text-xs">
          <div className="flex items-center gap-1.5">
            <div className="h-2 w-2 rounded-full bg-warning" />
            <span className="text-muted-foreground">Só catálogo:</span>
          </div>
          <span className="font-medium text-warning">{catalogUsers.toLocaleString()}</span>
        </div>
        <div className="flex items-center justify-between text-xs">
          <div className="flex items-center gap-1.5">
            <div className="h-2 w-2 rounded-full bg-muted-foreground/30" />
            <span className="text-muted-foreground">Inativos (7d):</span>
          </div>
          <div className="flex items-center gap-1.5">
            <span className="font-medium text-muted-foreground">{inactiveUsers.toLocaleString()}</span>
            <InactiveUsersExportButton inactiveCount={inactiveUsers} />
          </div>
        </div>
      </div>
    </div>
  );
}