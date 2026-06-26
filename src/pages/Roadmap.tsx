import React from "react";
import { RoadmapBoard } from "@/components/governance/RoadmapBoard";

export default function Roadmap() {
  return (
    <div className="flex-1 space-y-4 p-8 pt-6 animate-in fade-in slide-in-from-bottom-2">
      <div className="flex items-center justify-between">
        <h2 className="text-3xl font-bold tracking-tight">Roadmap</h2>
        <span className="text-sm text-muted-foreground">Visualização somente leitura</span>
      </div>
      <RoadmapBoard />
    </div>
  );
}
