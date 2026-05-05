import React, { useState } from "react";
import { useMatchConfig, useMatchSimulator } from "@/hooks/useMatchConfig";
import { Card, CardHeader, CardTitle, CardContent, CardDescription, CardFooter } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Play, Loader2, Info } from "lucide-react";
import { SimulationInput } from "@/services/matchEngineService";

export default function MatchSimulator() {
  const { weights } = useMatchConfig();
  const { simulate, isSimulating, simulationResults } = useMatchSimulator();

  const [input, setInput] = useState<SimulationInput>({
    enem_score: 650,
    family_income_per_capita: 1200,
    course_interest: ["Medicina", "Engenharia"],
    quota_types: ["L1", "L2"],
    state_preference: "SP"
  });

  const handleSimulate = async () => {
    if (weights.length > 0) {
      await simulate(input, weights);
    }
  };

  return (
    <div className="grid grid-cols-1 lg:grid-cols-[300px_1fr] gap-6">
      {/* Parameters Panel */}
      <Card className="h-fit">
        <CardHeader>
          <CardTitle className="text-base">Perfil de Simulação</CardTitle>
          <CardDescription>Defina os atributos do candidato simulado.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="enem">Nota ENEM</Label>
            <Input 
              id="enem" 
              type="number" 
              value={input.enem_score || ""} 
              onChange={(e) => setInput({...input, enem_score: Number(e.target.value) || null})} 
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="income">Renda Per Capita (RS)</Label>
            <Input 
              id="income" 
              type="number" 
              value={input.family_income_per_capita || ""} 
              onChange={(e) => setInput({...input, family_income_per_capita: Number(e.target.value) || null})} 
            />
          </div>
          <div className="space-y-2">
            <Label>Interesses (Vírgula para múltiplos)</Label>
            <Input 
              value={input.course_interest.join(", ")} 
              onChange={(e) => setInput({...input, course_interest: e.target.value.split(",").map(i => i.trim()).filter(Boolean)})} 
              placeholder="Ex: Direito, Letras"
            />
          </div>
          <div className="space-y-2">
            <Label>Cotas Aplicáveis</Label>
            <Input 
              value={input.quota_types.join(", ")} 
              onChange={(e) => setInput({...input, quota_types: e.target.value.split(",").map(i => i.trim()).filter(Boolean)})} 
              placeholder="Ex: L1, PPI"
            />
          </div>
        </CardContent>
        <CardFooter className="pt-2">
          <Button onClick={handleSimulate} disabled={isSimulating} className="w-full">
            {isSimulating ? <Loader2 className="h-4 w-4 mr-2 animate-spin" /> : <Play className="h-4 w-4 mr-2" />}
            Gerar Rank Simulado
          </Button>
        </CardFooter>
      </Card>

      {/* Results Panel */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center justify-between">
            Top 10 Oportunidades (Amostragem)
            <Badge variant="outline" className="font-normal text-muted-foreground">
              <Info className="h-3 w-3 mr-1" /> Simulação Client-Side
            </Badge>
          </CardTitle>
          <CardDescription>
            Abaixo estão as oportunidades ranqueadas usando os pesos e boosts ATUAIS definidos na "Calibração". Ao simular via app, usamos a RPC na nuvem.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {!simulationResults ? (
            <div className="py-12 text-center border border-dashed rounded-lg text-muted-foreground bg-muted/5">
              O simulador extrairá uma amostra real de 50 vagas do Supabase e aplicará os pesos do formulário da esquerda. Clique em "Gerar Rank" para validar o comportamento dos pesos.
            </div>
          ) : (
            <div className="rounded-md border">
              <Table>
                <TableHeader className="bg-muted/30">
                  <TableRow>
                    <TableHead className="w-16">Rank</TableHead>
                    <TableHead>Score (% Match)</TableHead>
                    <TableHead>Tipo de Vaga</TableHead>
                    <TableHead>Detalhes Base</TableHead>
                    <TableHead className="text-right">Ação</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {simulationResults.map((res, index) => (
                    <TableRow key={res.unified_opportunity_id}>
                      <TableCell className="font-medium text-muted-foreground">#{index + 1}</TableCell>
                      <TableCell>
                        <Badge variant={res.match_score >= 80 ? "default" : (res.match_score > 50 ? "secondary" : "outline")}
                          className={res.match_score >= 80 ? "bg-green-500 hover:bg-green-600" : ""}
                        >
                          {res.match_score}%
                        </Badge>
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center gap-2">
                          {res.is_partner ? (
                            <Badge variant="default" className="bg-purple-500/10 text-purple-600 hover:bg-purple-500/20 border-purple-200">Parceiro Nubo</Badge>
                          ) : (
                            <Badge variant="outline" className="bg-blue-500/10 text-blue-600 border-blue-200">MEC / Governo</Badge>
                          )}
                        </div>
                      </TableCell>
                      <TableCell className="text-xs text-muted-foreground font-mono">
                        base: {res.match_details.base_score} |
                        acad: {res.match_details.academic_score} |
                        {res.match_details.boost_applied ? " boost:✓" : ""}
                        {!res.match_details.meets_income ? " renda:✗" : ""}
                      </TableCell>
                      <TableCell className="text-right">
                        <Button variant="ghost" size="sm" className="hidden opacity-50 cursor-not-allowed">
                          Ver Detalhes
                        </Button>
                      </TableCell>
                    </TableRow>
                  ))}
                  {simulationResults.length === 0 && (
                    <TableRow>
                      <TableCell colSpan={5} className="text-center py-6 text-muted-foreground">
                        Nenhuma oportunidade amostrada. Verifique o DB.
                      </TableCell>
                    </TableRow>
                  )}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
