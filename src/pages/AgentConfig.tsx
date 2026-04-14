import React from "react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import SystemInstructionsEditor from "@/components/agent/SystemInstructionsEditor";
import StartersManager from "@/components/agent/StartersManager";
import SystemIntentsViewer from "@/components/agent/SystemIntentsViewer";

export default function AgentConfig() {
  return (
    <div className="flex-1 space-y-4 p-8 pt-6">
      <div className="flex items-center justify-between space-y-2">
        <div>
          <h2 className="text-3xl font-bold tracking-tight">Agent Config</h2>
          <p className="text-muted-foreground">
            Gerencie o comportamento cognitivo, prompts e sugestões de engajamento da Cloudinha.
          </p>
        </div>
      </div>
      
      <Tabs defaultValue="instructions" className="space-y-4">
        <TabsList className="bg-muted/50 border">
          <TabsTrigger value="instructions">System Instructions</TabsTrigger>
          <TabsTrigger value="starters">Conversation Starters</TabsTrigger>
          <TabsTrigger value="intents">System Intents</TabsTrigger>
        </TabsList>
        
        <TabsContent value="instructions" className="space-y-4">
          <SystemInstructionsEditor />
        </TabsContent>
        
        <TabsContent value="starters" className="space-y-4">
          <StartersManager />
        </TabsContent>

        <TabsContent value="intents" className="space-y-4">
          <SystemIntentsViewer />
        </TabsContent>
      </Tabs>
    </div>
  );
}
