import React, { useState } from "react";
import { PlusCircle, Bug, Lightbulb } from "lucide-react";
import { SupportBoard } from "@/components/governance/SupportBoard";
import { BugReportForm } from "@/components/governance/BugReportForm";
import { FeatureRequestForm } from "@/components/governance/FeatureRequestForm";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useQueryClient } from "@tanstack/react-query";

export default function Support() {
  const [isModalOpen, setIsModalOpen] = useState(false);
  const queryClient = useQueryClient();

  function handleSuccess() {
    setIsModalOpen(false);
    queryClient.invalidateQueries({ queryKey: ["snaps-support-cards"] });
  }

  return (
    <div className="flex-1 space-y-4 p-8 pt-6 animate-in fade-in slide-in-from-bottom-2">
      <div className="flex items-center justify-between">
        <h2 className="text-3xl font-bold tracking-tight">Suporte & QA</h2>
        <Button onClick={() => setIsModalOpen(true)}>
          <PlusCircle className="mr-2 h-4 w-4" />
          Abrir Chamado
        </Button>
      </div>

      <SupportBoard />

      <Dialog open={isModalOpen} onOpenChange={(open) => !open && setIsModalOpen(false)}>
        <DialogContent className="sm:max-w-[600px] max-h-[90vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Novo Chamado</DialogTitle>
          </DialogHeader>
          <Tabs defaultValue="bug">
            <TabsList className="mb-4">
              <TabsTrigger value="bug" className="flex items-center gap-2">
                <Bug className="h-4 w-4" /> Reportar Bug
              </TabsTrigger>
              <TabsTrigger value="feature" className="flex items-center gap-2">
                <Lightbulb className="h-4 w-4" /> Sugerir Melhoria
              </TabsTrigger>
            </TabsList>
            <TabsContent value="bug">
              <BugReportForm onSuccess={handleSuccess} onCancel={() => setIsModalOpen(false)} />
            </TabsContent>
            <TabsContent value="feature">
              <FeatureRequestForm onSuccess={handleSuccess} onCancel={() => setIsModalOpen(false)} />
            </TabsContent>
          </Tabs>
        </DialogContent>
      </Dialog>
    </div>
  );
}
