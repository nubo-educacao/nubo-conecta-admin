import React from "react";
import { useQuery } from "@tanstack/react-query";
import { fetchRoadmapSprints, type SnapsSprint, type SnapsCard } from "@/services/snapsApiService";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { AlertCircle } from "lucide-react";

const SPRINT_STATUS_CONFIG: Record<string, { label: string; className: string }> = {
  active: { label: "Ativa", className: "bg-green-600" },
  planning: { label: "Planejamento", className: "bg-blue-500" },
  done: { label: "Concluída", className: "bg-slate-500" },
  backlog: { label: "Backlog", className: "bg-slate-400" },
};

const CARD_STATUS_CONFIG: Record<string, { label: string; className: string }> = {
  todo: { label: "A Fazer", className: "bg-slate-200 text-slate-700" },
  in_progress: { label: "Em Progresso", className: "bg-blue-100 text-blue-700" },
  assurance: { label: "Validação", className: "bg-yellow-100 text-yellow-800" },
  done: { label: "Concluído", className: "bg-green-100 text-green-700" },
  backlog: { label: "Backlog", className: "bg-slate-100 text-slate-600" },
};

function sprintStatusConfig(status: string) {
  return SPRINT_STATUS_CONFIG[status] ?? { label: status, className: "bg-slate-500" };
}

function cardStatusConfig(status: string) {
  return CARD_STATUS_CONFIG[status] ?? { label: status, className: "bg-slate-100 text-slate-600" };
}

export function RoadmapBoard() {
  const { data: sprints, isLoading, isError, error } = useQuery<SnapsSprint[]>({
    queryKey: ["snaps-roadmap-sprints"],
    queryFn: fetchRoadmapSprints,
  });

  if (isLoading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-40 w-full" />
        <Skeleton className="h-40 w-full" />
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

  if (!sprints || sprints.length === 0) {
    return (
      <div className="py-10 text-center text-muted-foreground text-sm">
        Nenhuma sprint encontrada no roadmap.
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {sprints.map((sprint) => {
        const cfg = sprintStatusConfig(sprint.status);
        return (
          <Card key={sprint.id}>
            <CardHeader className="pb-2">
              <div className="flex items-center justify-between">
                <CardTitle className="text-base">{sprint.name}</CardTitle>
                <Badge className={cfg.className}>{cfg.label}</Badge>
              </div>
            </CardHeader>
            {sprint.cards && sprint.cards.length > 0 && (
              <CardContent>
                <ul className="space-y-2">
                  {sprint.cards.map((card: SnapsCard) => {
                    const cardCfg = cardStatusConfig(card.status);
                    return (
                      <li key={card.id} className="flex items-center justify-between text-sm">
                        <span className="text-muted-foreground truncate pr-4">{card.title}</span>
                        <Badge variant="outline" className={`${cardCfg.className} shrink-0 text-xs`}>
                          {cardCfg.label}
                        </Badge>
                      </li>
                    );
                  })}
                </ul>
              </CardContent>
            )}
          </Card>
        );
      })}
    </div>
  );
}
