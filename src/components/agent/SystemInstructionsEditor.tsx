import React, { useState, useEffect } from "react";
import { useAgentPrompts } from "@/hooks/useAgentConfig";
import { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Bot, Save, Loader2 } from "lucide-react";
import { AgentPrompt } from "@/services/agentConfigService";

export default function SystemInstructionsEditor() {
  const { prompts, isLoading, isError, updatePrompt } = useAgentPrompts();
  const [localPrompts, setLocalPrompts] = useState<Record<string, AgentPrompt>>({});
  const [savingKeys, setSavingKeys] = useState<Record<string, boolean>>({});

  useEffect(() => {
    if (prompts.length > 0) {
      const map: Record<string, AgentPrompt> = {};
      prompts.forEach((p) => {
        map[p.agent_key] = p;
      });
      setLocalPrompts(map);
    }
  }, [prompts]);

  const handleUpdate = async (key: string) => {
    const prompt = localPrompts[key];
    if (!prompt) return;

    setSavingKeys((prev) => ({ ...prev, [key]: true }));
    try {
      await updatePrompt({
        id: prompt.id,
        data: {
          system_instruction: prompt.system_instruction,
          temperature: prompt.temperature,
        }
      });
    } finally {
      setSavingKeys((prev) => ({ ...prev, [key]: false }));
    }
  };

  if (isLoading) {
    return <div className="flex justify-center p-8"><Loader2 className="h-8 w-8 animate-spin text-muted-foreground" /></div>;
  }

  if (isError) {
    return <div className="text-red-500 p-4 border border-red-200 bg-red-50 rounded-lg">Erro ao carregar prompts. Tente atualizar a página.</div>;
  }

  const agentKeys = ["planning", "reasoning", "response"]; // Fix order

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-2 mb-4">
        <Bot className="h-6 w-6 text-primary" />
        <h2 className="text-lg font-semibold">System Instructions dos Agentes</h2>
      </div>
      <p className="text-sm text-muted-foreground mb-6">
        Estes são os prompts vitais (System Instructions) que definem a persona e o comportamento de cada agente do pipeline.
        Alterações afetarão diretamente como a Cloudinha planeja, raciocina e responde as dúvidas dos usuários em Produção.
      </p>

      {agentKeys.map((key) => {
        const prompt = localPrompts[key];
        if (!prompt) return null;
        
        const isSaving = savingKeys[key] || false;

        return (
          <Card key={key} className="overflow-hidden border-primary/20">
            <CardHeader className="bg-primary/5 pb-4">
              <CardTitle className="capitalize flex justify-between items-center text-primary">
                Agente: {key}
              </CardTitle>
              <CardDescription>
                Atualizado em: {new Date(prompt.is_active ? prompt.updated_at || new Date() : new Date()).toLocaleString('pt-BR')}
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-4 pt-6">
              <div className="space-y-2">
                <Label htmlFor={`instructions-${key}`}>Instruções do Sistema (Prompt Principal)</Label>
                <Textarea
                  id={`instructions-${key}`}
                  className="min-h-[250px] font-mono text-sm resize-y"
                  value={prompt.system_instruction}
                  onChange={(e) => setLocalPrompts({
                    ...localPrompts,
                    [key]: { ...prompt, system_instruction: e.target.value }
                  })}
                />
              </div>
              <div className="space-y-2 flex flex-col max-w-xs">
                <Label htmlFor={`temp-${key}`}>Temperatura (0.0 a 2.0)</Label>
                <div className="flex items-center gap-4">
                  <Input 
                    id={`temp-${key}`}
                    type="number"
                    step="0.05"
                    min="0"
                    max="2"
                    value={prompt.temperature || 0}
                    onChange={(e) => setLocalPrompts({
                      ...localPrompts,
                      [key]: { ...prompt, temperature: parseFloat(e.target.value) }
                    })}
                  />
                  <span className="text-xs text-muted-foreground whitespace-nowrap">
                    {key === "planning" ? "Recomendado baixo (~0.1)" : 
                     key === "reasoning" ? "Recomendado baixo (~0.2)" : 
                     "Recomendado natural (~0.7)"}
                  </span>
                </div>
              </div>
            </CardContent>
            <CardFooter className="bg-muted/30 flex justify-end border-t">
              <Button onClick={() => handleUpdate(key)} disabled={isSaving}>
                {isSaving ? <Loader2 className="h-4 w-4 mr-2 animate-spin" /> : <Save className="h-4 w-4 mr-2" />}
                Salvar Configurações
              </Button>
            </CardFooter>
          </Card>
        );
      })}
    </div>
  );
}
