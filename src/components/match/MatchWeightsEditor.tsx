import React, { useState, useEffect } from "react";
import { useMatchConfig } from "@/hooks/useMatchConfig";
import { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Slider } from "@/components/ui/slider";
import { Input } from "@/components/ui/input";
import { Save, Sliders, Loader2 } from "lucide-react";
import { MatchWeight } from "@/services/matchEngineService";

export default function MatchWeightsEditor() {
  const { weights, isLoading, isError, updateWeight } = useMatchConfig();
  const [localWeights, setLocalWeights] = useState<Record<string, MatchWeight>>({});
  const [savingId, setSavingId] = useState<string | null>(null);

  useEffect(() => {
    if (weights.length > 0) {
      const map: Record<string, MatchWeight> = {};
      weights.forEach((w) => {
        map[w.id] = w;
      });
      setLocalWeights(map);
    }
  }, [weights]);

  const handleUpdate = async (id: string) => {
    const w = localWeights[id];
    if (!w) return;

    setSavingId(id);
    try {
      await updateWeight({ id, value: w.weight_value });
    } finally {
      setSavingId(null);
    }
  };

  const handleValueChange = (id: string, newVal: number) => {
    setLocalWeights(prev => ({
      ...prev,
      [id]: { ...prev[id], weight_value: newVal }
    }));
  };

  if (isLoading) {
    return <div className="flex justify-center p-8"><Loader2 className="h-8 w-8 animate-spin text-muted-foreground" /></div>;
  }

  if (isError) {
    return <div className="text-red-500 p-4 border border-red-200 bg-red-50 rounded-lg">Erro ao carregar pesos do match.</div>;
  }

  const compositionWeights = Object.values(localWeights).filter(w => w.category === 'v3_pillar' || w.category === 'score_composition');
  const decayWeights = Object.values(localWeights).filter(w => w.category === 'score_decay');
  const boostWeights = Object.values(localWeights).filter(w => w.category === 'boost');

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-2 mb-4">
        <Sliders className="h-6 w-6 text-primary" />
        <h2 className="text-lg font-semibold">Calibração do Motor de Match</h2>
      </div>
      <p className="text-sm text-muted-foreground mb-6">
        Edite os multiplicadores e pesos que ditam a relevância de cada fator no algoritmo de Match. Salvar aplica imediatamente o recálculo nos novos Matches gerados.
      </p>

      {/* Composição Ponderada */}
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Pesos de Composição do ScoreBase</CardTitle>
          <CardDescription>A soma destes não precisa obrigatoriamente ser 1.0 (o motor normaliza), mas as frações indicam a relatividade de cada pilar.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-6">
          {compositionWeights.map((w) => (
            <div key={w.id} className="grid grid-cols-[1fr_80px_100px] gap-6 items-center">
              <div className="space-y-2">
                <Label className="text-sm font-medium flex items-center justify-between">
                  {w.weight_key}
                  <span className="text-xs text-muted-foreground font-normal">{w.description}</span>
                </Label>
                <Slider
                  min={0}
                  max={1}
                  step={0.01}
                  value={[w.weight_value]}
                  onValueChange={(vals) => handleValueChange(w.id, vals[0])}
                  className="w-full"
                />
              </div>
              <div className="pt-6">
                <Input 
                  type="number" 
                  step="0.01" 
                  value={w.weight_value} 
                  onChange={(e) => handleValueChange(w.id, parseFloat(e.target.value) || 0)} 
                  className="h-8 text-right"
                />
              </div>
              <div className="pt-6">
                <Button size="sm" variant="outline" onClick={() => handleUpdate(w.id)} disabled={savingId === w.id} className="w-full">
                  {savingId === w.id ? <Loader2 className="h-4 w-4 animate-spin" /> : "Salvar"}
                </Button>
              </div>
            </div>
          ))}
        </CardContent>
      </Card>

      {/* Decaimento de Notas (Curva Assimétrica) */}
      {decayWeights.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-lg">Curva Assimétrica de Decaimento de Nota</CardTitle>
            <CardDescription>
              Configuração das penalidades aplicadas por ponto de diferença em relação à nota de corte do curso.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-6">
            {decayWeights.map((w) => (
              <div key={w.id} className="grid grid-cols-[1fr_80px_100px] gap-6 items-center">
                <div className="space-y-2">
                  <Label className="text-sm font-medium flex items-center justify-between">
                    {w.weight_key}
                    <span className="text-xs text-muted-foreground font-normal">{w.description}</span>
                  </Label>
                  <Slider
                    min={0}
                    max={2}
                    step={0.05}
                    value={[w.weight_value]}
                    onValueChange={(vals) => handleValueChange(w.id, vals[0])}
                    className="w-full"
                  />
                </div>
                <div className="pt-6">
                  <Input 
                    type="number" 
                    step="0.05" 
                    value={w.weight_value} 
                    onChange={(e) => handleValueChange(w.id, parseFloat(e.target.value) || 0)} 
                    className="h-8 text-right"
                  />
                </div>
                <div className="pt-6">
                  <Button size="sm" variant="outline" onClick={() => handleUpdate(w.id)} disabled={savingId === w.id} className="w-full">
                    {savingId === w.id ? <Loader2 className="h-4 w-4 animate-spin" /> : "Salvar"}
                  </Button>
                </div>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      {/* Multiplicadores e Boosts */}
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Boosters & Multiplicadores (Oportunidades Parceiras)</CardTitle>
          <CardDescription>Estes são aplicados em cima do Score Base final (após cálculo da composição ponderada).</CardDescription>
        </CardHeader>
        <CardContent className="space-y-6">
          {boostWeights.map((w) => (
            <div key={w.id} className="grid grid-cols-[1fr_80px_100px] gap-6 items-center">
              <div className="space-y-2">
                <Label className="text-sm font-medium flex items-center justify-between">
                  {w.weight_key}
                  <span className="text-xs text-muted-foreground font-normal">{w.description}</span>
                </Label>
                <Slider
                  min={1}
                  max={w.weight_key === 'partner_boost_cap' ? 40 : 2}
                  step={0.05}
                  value={[w.weight_value]}
                  onValueChange={(vals) => handleValueChange(w.id, vals[0])}
                  className="w-full"
                />
              </div>
              <div className="pt-6">
                <Input 
                  type="number" 
                  step="0.05" 
                  value={w.weight_value} 
                  onChange={(e) => handleValueChange(w.id, parseFloat(e.target.value) || 0)} 
                  className="h-8 text-right"
                />
              </div>
              <div className="pt-6">
                <Button size="sm" variant="outline" onClick={() => handleUpdate(w.id)} disabled={savingId === w.id} className="w-full">
                  {savingId === w.id ? <Loader2 className="h-4 w-4 animate-spin" /> : "Salvar"}
                </Button>
              </div>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
