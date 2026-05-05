import React, { useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Card, CardHeader, CardTitle, CardContent, CardDescription, CardFooter } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Loader2, Zap, User, AlertCircle } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";

interface ShadowResult {
  unified_opportunity_id: string;
  title: string;
  provider_name: string;
  match_score: number;
  is_partner: boolean;
  is_eligible: boolean;
  match_details: Record<string, any>;
}

interface UserPreviewData {
  full_name: string;
  enem_score: number | null;
  family_income_per_capita: number | null;
  quota_types: string[];
  course_interest: string[];
}

export default function ShadowTestPanel() {
  const [profileId, setProfileId] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingUser, setIsLoadingUser] = useState(false);
  const [results, setResults] = useState<ShadowResult[] | null>(null);
  const [userPreview, setUserPreview] = useState<UserPreviewData | null>(null);
  const [error, setError] = useState<string | null>(null);

  const loadUserPreview = async () => {
    if (!profileId.trim()) return;
    setIsLoadingUser(true);
    setError(null);
    setUserPreview(null);
    try {
      // Fetch profile + preferences in parallel
      const [profileRes, prefRes] = await Promise.all([
        supabase
          .from("user_profiles")
          .select("id, full_name")
          .eq("id", profileId.trim())
          .single(),
        supabase
          .from("user_preferences")
          .select("enem_score, family_income_per_capita, quota_types, course_interest")
          .eq("user_id", profileId.trim())
          .maybeSingle(),
      ]);

      if (profileRes.error || !profileRes.data) {
        setError(`Perfil não encontrado (ID: ${profileId})`);
        return;
      }

      setUserPreview({
        full_name: (profileRes.data as any).full_name ?? "Sem nome",
        enem_score: (prefRes.data as any)?.enem_score ?? null,
        family_income_per_capita: (prefRes.data as any)?.family_income_per_capita ?? null,
        quota_types: (prefRes.data as any)?.quota_types ?? [],
        course_interest: (prefRes.data as any)?.course_interest ?? [],
      });
    } catch (e: any) {
      setError("Erro ao carregar perfil: " + e.message);
    } finally {
      setIsLoadingUser(false);
    }
  };

  const pollMatchStatus = async (pid: string): Promise<string> => {
    const maxAttempts = 30; // 30 × 2s = 60s max
    for (let i = 0; i < maxAttempts; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      const { data } = await supabase
        .from("user_preferences")
        .select("match_status")
        .eq("user_id", pid)
        .maybeSingle();
      const status = (data as any)?.match_status;
      if (status === "ready" || status === "error") return status;
    }
    return "timeout";
  };

  const loadResults = async (pid: string) => {
    const { data: matches, error: matchErr } = await supabase
      .from("user_opportunity_matches")
      .select("unified_opportunity_id, match_score, is_eligible, match_details")
      .eq("user_id", pid)
      .order("match_score", { ascending: false })
      .limit(20);

    if (matchErr) {
      setError(`Erro ao ler matches: ${matchErr.message}`);
      return;
    }

    const ids = (matches as any[]).map((r: any) => r.unified_opportunity_id);
    const { data: opps } = await supabase
      .from("v_unified_opportunities")
      .select("unified_id, title, provider_name, is_partner")
      .in("unified_id", ids);

    const oppMap: Record<string, any> = {};
    for (const opp of opps ?? []) {
      oppMap[(opp as any).unified_id] = opp;
    }

    const enriched: ShadowResult[] = (matches as any[]).map((r: any) => ({
      unified_opportunity_id: r.unified_opportunity_id,
      title: oppMap[r.unified_opportunity_id]?.title ?? "—",
      provider_name: oppMap[r.unified_opportunity_id]?.provider_name ?? "—",
      match_score: r.match_score,
      is_partner: oppMap[r.unified_opportunity_id]?.is_partner ?? false,
      is_eligible: r.is_eligible ?? true,
      match_details: r.match_details ?? {},
    }));

    enriched.sort((a, b) => b.match_score - a.match_score);
    setResults(enriched);
  };

  const runShadowTest = async () => {
    if (!profileId.trim()) return;
    setIsLoading(true);
    setError(null);
    setResults(null);
    const pid = profileId.trim();
    try {
      // 1. Call the Edge Function (async — returns 202 immediately)
      const { error: fnError } = await supabase.functions.invoke("calculate-match", {
        body: { profile_id: pid },
      });

      if (fnError) {
        setError(`Erro na Edge Function calculate-match: ${fnError.message}`);
        return;
      }

      // 2. Poll until match_status = ready | error
      const finalStatus = await pollMatchStatus(pid);

      if (finalStatus === "error") {
        setError("O worker reportou erro ao calcular matches.");
        return;
      }
      if (finalStatus === "timeout") {
        setError("Timeout: cálculo não completou em 60s.");
        return;
      }

      // 3. Read materialized results
      await loadResults(pid);
    } catch (e: any) {
      setError("Erro inesperado: " + e.message);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="grid grid-cols-1 lg:grid-cols-[320px_1fr] gap-6">
      {/* Input Panel */}
      <div className="space-y-4">
        <Card>
          <CardHeader>
            <CardTitle className="text-base flex items-center gap-2">
              <Zap className="h-4 w-4 text-amber-500" />
              Shadow Testing
            </CardTitle>
            <CardDescription>
              Executa a Edge Function <code className="font-mono text-xs">calculate-match</code> (async) com um perfil real para auditar a lógica de elegibilidade e score.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="profile-id">Profile ID (UUID do usuário)</Label>
              <Input
                id="profile-id"
                placeholder="Ex: a3f9c2d1-..."
                value={profileId}
                onChange={(e) => {
                  setProfileId(e.target.value);
                  setUserPreview(null);
                  setResults(null);
                  setError(null);
                }}
              />
            </div>
            <Button
              variant="outline"
              size="sm"
              className="w-full"
              onClick={loadUserPreview}
              disabled={!profileId.trim() || isLoadingUser}
            >
              {isLoadingUser ? <Loader2 className="h-3 w-3 mr-2 animate-spin" /> : <User className="h-3 w-3 mr-2" />}
              Pré-visualizar Perfil
            </Button>
          </CardContent>

          {userPreview && (
            <CardContent className="pt-0 space-y-3 border-t">
              <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide mt-3">Dados do Perfil</p>
              <div className="text-sm space-y-1">
                <p><span className="font-medium">Nome:</span> {userPreview.full_name}</p>
                <p><span className="font-medium">ENEM:</span> {userPreview.enem_score ?? <span className="text-muted-foreground">Não informado</span>}</p>
                <p>
                  <span className="font-medium">Renda per capita:</span>{" "}
                  {userPreview.family_income_per_capita != null
                    ? `R$ ${userPreview.family_income_per_capita.toLocaleString("pt-BR")}`
                    : <span className="text-muted-foreground">Não informada</span>}
                </p>
                {userPreview.quota_types.length > 0 && (
                  <div className="flex flex-wrap gap-1 mt-1">
                    {userPreview.quota_types.map((q) => (
                      <Badge key={q} variant="secondary" className="text-[10px]">{q}</Badge>
                    ))}
                  </div>
                )}
              </div>
            </CardContent>
          )}

          <CardFooter className="pt-2">
            <Button
              onClick={runShadowTest}
              disabled={isLoading || !profileId.trim()}
              className="w-full"
            >
              {isLoading ? <Loader2 className="h-4 w-4 mr-2 animate-spin" /> : <Zap className="h-4 w-4 mr-2" />}
              Executar Shadow Test
            </Button>
          </CardFooter>
        </Card>

        {error && (
          <Alert variant="destructive">
            <AlertCircle className="h-4 w-4" />
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        )}
      </div>

      {/* Results Panel */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center justify-between">
            Resultados da RPC (Produção)
            <Badge variant="outline" className="font-normal text-amber-600 border-amber-300 bg-amber-50">
              <Zap className="h-3 w-3 mr-1" />
              Live RPC
            </Badge>
          </CardTitle>
          <CardDescription>
            Score e elegibilidade calculados pela Edge Function <code className="font-mono text-xs">calculate-match</code> (async) — dados reais, sem mock.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {!results ? (
            <div className="py-12 text-center border border-dashed rounded-lg text-muted-foreground bg-muted/5">
              {isLoading ? (
                <div className="flex flex-col items-center gap-3">
                  <Loader2 className="h-6 w-6 animate-spin text-primary" />
                  <p className="text-sm">Calculando matches em produção...</p>
                </div>
              ) : (
                <p className="text-sm">Informe um Profile ID e clique em "Executar Shadow Test" para ver os resultados reais do algoritmo.</p>
              )}
            </div>
          ) : results.length === 0 ? (
            <div className="py-12 text-center border border-dashed rounded-lg text-muted-foreground bg-amber-50">
              <p className="text-sm font-medium text-amber-700">Nenhuma oportunidade elegível encontrada para este perfil.</p>
              <p className="text-xs mt-1 text-amber-600">Verifique as regras de elegibilidade (renda, nota de corte) no match_config.</p>
            </div>
          ) : (
            <div className="rounded-md border">
              <Table>
                <TableHeader className="bg-muted/30">
                  <TableRow>
                    <TableHead className="w-12">#</TableHead>
                    <TableHead className="w-24">Score</TableHead>
                    <TableHead>Oportunidade</TableHead>
                    <TableHead>Tipo</TableHead>
                    <TableHead>Detalhes</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {results.map((res, index) => (
                    <TableRow key={res.unified_opportunity_id} className={!res.is_eligible ? "opacity-50" : ""}>
                      <TableCell className="font-medium text-muted-foreground text-xs">#{index + 1}</TableCell>
                      <TableCell>
                        <Badge
                          variant={res.match_score >= 80 ? "default" : res.match_score > 50 ? "secondary" : "outline"}
                          className={res.match_score >= 80 ? "bg-green-500 hover:bg-green-600" : ""}
                        >
                          {res.match_score}%
                        </Badge>
                      </TableCell>
                      <TableCell>
                        <div>
                          <p className="text-xs font-medium line-clamp-1">{res.title}</p>
                          <p className="text-[11px] text-muted-foreground">{res.provider_name}</p>
                        </div>
                      </TableCell>
                      <TableCell>
                        {res.is_partner ? (
                          <Badge variant="default" className="bg-purple-500/10 text-purple-600 hover:bg-purple-500/20 border-purple-200 text-[10px]">
                            Parceiro
                          </Badge>
                        ) : (
                          <Badge variant="outline" className="bg-blue-500/10 text-blue-600 border-blue-200 text-[10px]">
                            MEC
                          </Badge>
                        )}
                      </TableCell>
                      <TableCell className="text-[10px] text-muted-foreground font-mono space-y-0.5">
                        {res.match_details?.meets_income != null && (
                          <span className={res.match_details.meets_income ? "text-green-600" : "text-red-500"}>
                            renda:{res.match_details.meets_income ? "✓" : "✗"}{" "}
                          </span>
                        )}
                        {res.match_details?.academic_score != null && (
                          <span>acad:{res.match_details.academic_score} </span>
                        )}
                        {res.match_details?.course_score != null && (
                          <span>curso:{res.match_details.course_score} </span>
                        )}
                        {res.match_details?.distance_score != null && (
                          <span>loc:{res.match_details.distance_score} </span>
                        )}
                        {res.match_details?.boost_applied && <span className="text-purple-600">boost:✓ </span>}
                        {res.match_details?.idle_vacancy_boost_applied && <span className="text-amber-600">idle:✓</span>}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
