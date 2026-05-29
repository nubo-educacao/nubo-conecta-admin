import React, { useState, useEffect } from "react";
import { useAgentPrompts } from "@/hooks/useAgentConfig";
import { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
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
          model: prompt.model,
          max_steps: prompt.max_steps,
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

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-2 mb-4">
        <Bot className="h-6 w-6 text-primary" />
        <h2 className="text-lg font-semibold">Configuração e Prompts dos Agentes</h2>
      </div>
      <p className="text-sm text-muted-foreground mb-6">
        Estes são os prompts vitais e parâmetros de execução dos agentes.
        Alterações afetarão diretamente como o loop ReAct executa e consome ferramentas em Produção.
      </p>

      {prompts.map((p) => {
        const key = p.agent_key;
        const prompt = localPrompts[key];
        if (!prompt) return null;
        
        const isSaving = savingKeys[key] || false;

        return (
          <Card key={key} className="overflow-hidden border-primary/20">
            <CardHeader className="bg-primary/5 pb-4">
              <CardTitle className="capitalize flex justify-between items-center text-primary font-mono text-base">
                Chave do Agente: {key}
              </CardTitle>
              <CardDescription>
                Atualizado em: {prompt.updated_at ? new Date(prompt.updated_at).toLocaleString('pt-BR') : 'Sem registro'}
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-6 pt-6">
              <div className="space-y-2">
                <Label htmlFor={`instructions-${key}`} className="font-medium text-sm text-slate-700">
                  Instruções do Sistema (Prompt Principal)
                </Label>
                <p className="text-[11px] text-muted-foreground bg-muted/50 border rounded px-3 py-2 font-mono">
                  <span className="font-semibold text-slate-600">Variáveis disponíveis:</span>{' '}
                  <code>{'{{SCHEMA_CONTEXT}}'}</code> — DDL das tabelas do catálogo &nbsp;·&nbsp;
                  <code>{'{{AVAILABLE_TOOLS}}'}</code> — lista de ferramentas MCP &nbsp;·&nbsp;
                  <code>{'{{CURRENT_DATETIME}}'}</code> — data e hora atual em Brasília (pt-BR) &nbsp;·&nbsp;
                  <code>{'{{FEW_SHOT_EXAMPLES}}'}</code> — exemplos curados (Learning Examples)
                </p>
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

              <div className="grid grid-cols-1 md:grid-cols-3 gap-6 pt-2">
                {/* Temperatura */}
                <div className="space-y-2">
                  <Label htmlFor={`temp-${key}`}>Temperatura (0.0 a 2.0)</Label>
                  <Input 
                    id={`temp-${key}`}
                    type="number"
                    step="0.05"
                    min="0"
                    max="2"
                    value={prompt.temperature ?? 0.7}
                    onChange={(e) => setLocalPrompts({
                      ...localPrompts,
                      [key]: { ...prompt, temperature: parseFloat(e.target.value) || 0 }
                    })}
                  />
                  <p className="text-[10px] text-muted-foreground">
                    Valores baixos são mais consistentes; altos são mais criativos.
                  </p>
                </div>

                {/* Modelo LLM */}
                <div className="space-y-2">
                  <Label htmlFor={`model-${key}`}>Modelo LLM</Label>
                  <Select
                    value={prompt.model ?? "gemini-2.5-flash"}
                    onValueChange={(val) => setLocalPrompts({
                      ...localPrompts,
                      [key]: { ...prompt, model: val }
                    })}
                  >
                    <SelectTrigger id={`model-${key}`}>
                      <SelectValue placeholder="Selecione o modelo" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="gemini-2.5-flash">Gemini 2.5 Flash</SelectItem>
                      <SelectItem value="gemini-2.5-pro">Gemini 2.5 Pro</SelectItem>
                      <SelectItem value="gemini-1.5-flash">Gemini 1.5 Flash</SelectItem>
                      <SelectItem value="gemini-1.5-pro">Gemini 1.5 Pro</SelectItem>
                    </SelectContent>
                  </Select>
                  <p className="text-[10px] text-muted-foreground">
                    Define o modelo cognitivo e a velocidade de resposta.
                  </p>
                </div>

                {/* Limite de Steps (ReAct) */}
                <div className="space-y-2">
                  <Label htmlFor={`max-steps-${key}`}>Máximo de Steps (ReAct)</Label>
                  <Input 
                    id={`max-steps-${key}`}
                    type="number"
                    step="1"
                    min="1"
                    max="20"
                    value={prompt.max_steps ?? 5}
                    onChange={(e) => setLocalPrompts({
                      ...localPrompts,
                      [key]: { ...prompt, max_steps: parseInt(e.target.value) || 5 }
                    })}
                  />
                  <p className="text-[10px] text-muted-foreground">
                    Evita loops infinitos e garante paradas de segurança.
                  </p>
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
