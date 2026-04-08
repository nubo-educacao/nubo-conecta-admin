import React from "react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import MatchWeightsEditor from "@/components/match/MatchWeightsEditor";
import MatchSimulator from "@/components/match/MatchSimulator";

export default function MatchEngine() {
  return (
    <div className="flex-1 space-y-4 p-8 pt-6">
      <div className="flex items-center justify-between space-y-2">
        <div>
          <h2 className="text-3xl font-bold tracking-tight">Match Engine</h2>
          <p className="text-muted-foreground">
            Calibre os algoritmos de recomendação de oportunidades e avalie o impacto das regras de negócio.
          </p>
        </div>
      </div>
      
      <Tabs defaultValue="calibration" className="space-y-4">
        <TabsList className="bg-muted/50 border">
          <TabsTrigger value="calibration">Calibração (Pesos)</TabsTrigger>
          <TabsTrigger value="simulator">Simulador Tático</TabsTrigger>
        </TabsList>
        
        <TabsContent value="calibration" className="space-y-4">
          <MatchWeightsEditor />
        </TabsContent>
        
        <TabsContent value="simulator" className="space-y-4">
          <MatchSimulator />
        </TabsContent>
      </Tabs>
    </div>
  );
}
