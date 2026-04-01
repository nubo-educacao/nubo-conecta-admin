import { useState, useEffect, useCallback } from "react";
import { AlertTriangle, TrendingDown, MessageSquare, Lightbulb, RefreshCw, Loader2, Sparkles, Clock, AlertCircle } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { supabase } from "@/integrations/supabase/client";
import { useToast } from "@/hooks/use-toast";
import { formatDistanceToNow } from "date-fns";
import { ptBR } from "date-fns/locale";

interface Insight {
  category: "alert" | "bottleneck" | "pattern" | "opportunity";
  title: string;
  description: string;
  action: string;
  priority: "high" | "medium" | "low";
}

interface InsightsResponse {
  insights: Insight[];
  generatedAt: string;
  fromCache?: boolean;
  dataChanged?: boolean;
  dataContext?: {
    totalMessages: number;
    userMessages: number;
    funnelStages: number;
  };
}

const categoryConfig = {
  alert: {
    icon: AlertTriangle,
    label: "Alerta",
    color: "bg-destructive/10 text-destructive border-destructive/20",
  },
  bottleneck: {
    icon: TrendingDown,
    label: "Gargalo",
    color: "bg-orange-500/10 text-orange-600 border-orange-500/20",
  },
  pattern: {
    icon: MessageSquare,
    label: "Padrão",
    color: "bg-blue-500/10 text-blue-600 border-blue-500/20",
  },
  opportunity: {
    icon: Lightbulb,
    label: "Oportunidade",
    color: "bg-green-500/10 text-green-600 border-green-500/20",
  },
};

const priorityConfig = {
  high: "bg-destructive text-destructive-foreground",
  medium: "bg-yellow-500 text-yellow-950",
  low: "bg-muted text-muted-foreground",
};

const COOLDOWN_DURATION_MS = 10 * 60 * 1000; // 10 minutes

export function AIInsightsPanel() {
  const [insights, setInsights] = useState<Insight[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [isInitialLoad, setIsInitialLoad] = useState(true);
  const [generatedAt, setGeneratedAt] = useState<string | null>(null);
  const [fromCache, setFromCache] = useState(false);
  const [dataChanged, setDataChanged] = useState(false);
  const [lastGeneratedAt, setLastGeneratedAt] = useState<number | null>(null);
  const [cooldownRemaining, setCooldownRemaining] = useState(0);
  const { toast } = useToast();

  // Calculate cooldown
  useEffect(() => {
    if (!lastGeneratedAt) return;

    const updateCooldown = () => {
      const elapsed = Date.now() - lastGeneratedAt;
      const remaining = Math.max(0, COOLDOWN_DURATION_MS - elapsed);
      setCooldownRemaining(remaining);
    };

    updateCooldown();
    const interval = setInterval(updateCooldown, 1000);
    return () => clearInterval(interval);
  }, [lastGeneratedAt]);

  const isCooldownActive = cooldownRemaining > 0 && !dataChanged;

  const formatCooldown = (ms: number) => {
    const minutes = Math.floor(ms / 60000);
    const seconds = Math.floor((ms % 60000) / 1000);
    return `${minutes}:${seconds.toString().padStart(2, '0')}`;
  };

  const fetchInsights = useCallback(async (forceRefresh = false) => {
    setIsLoading(true);
    try {
      const { data, error } = await supabase.functions.invoke("ai-insights", {
        body: { forceRefresh }
      });

      if (error) {
        throw error;
      }

      const response = data as InsightsResponse;
      setInsights(response.insights || []);
      setGeneratedAt(response.generatedAt);
      setFromCache(response.fromCache || false);
      setDataChanged(response.dataChanged || false);

      // Set cooldown timestamp when new insights are generated
      if (!response.fromCache) {
        setLastGeneratedAt(Date.now());
      }
    } catch (error) {
      console.error("Error fetching insights:", error);
      toast({
        variant: "destructive",
        title: "Erro ao gerar insights",
        description: "Não foi possível conectar com a AI. Tente novamente.",
      });
    } finally {
      setIsLoading(false);
      setIsInitialLoad(false);
    }
  }, [toast]);

  useEffect(() => {
    fetchInsights(false); // Load from cache initially
  }, []);

  const handleRefresh = () => {
    fetchInsights(true);
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-primary/10">
            <Sparkles className="h-4 w-4 text-primary" />
          </div>
          <div>
            <h2 className="text-lg font-semibold">Insights Automáticos</h2>
            {generatedAt && (
              <div className="flex items-center gap-2">
                <p className="text-xs text-muted-foreground flex items-center gap-1">
                  <Clock className="h-3 w-3" />
                  Gerado {formatDistanceToNow(new Date(generatedAt), { addSuffix: true, locale: ptBR })}
                  {fromCache && <span className="text-muted-foreground/70">(cache)</span>}
                </p>
              </div>
            )}
          </div>
        </div>
        
        <div className="flex items-center gap-2">
          {dataChanged && (
            <Badge variant="outline" className="bg-yellow-500/10 text-yellow-600 border-yellow-500/20">
              <AlertCircle className="h-3 w-3 mr-1" />
              Novos dados disponíveis
            </Badge>
          )}
          
          <Button
            variant={dataChanged ? "default" : "outline"}
            size="sm"
            onClick={handleRefresh}
            disabled={isLoading || isCooldownActive}
          >
            {isLoading ? (
              <Loader2 className="h-4 w-4 animate-spin mr-2" />
            ) : (
              <RefreshCw className="h-4 w-4 mr-2" />
            )}
            {isCooldownActive 
              ? `Aguarde ${formatCooldown(cooldownRemaining)}` 
              : "Atualizar Insights"}
          </Button>
        </div>
      </div>

      {isLoading && insights.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-12 text-center">
          <div className="relative">
            <div className="h-16 w-16 rounded-full bg-primary/10 flex items-center justify-center">
              <Sparkles className="h-8 w-8 text-primary animate-pulse" />
            </div>
            <Loader2 className="absolute -bottom-1 -right-1 h-6 w-6 text-primary animate-spin" />
          </div>
          <p className="mt-4 text-muted-foreground">
            {isInitialLoad ? "Carregando insights do cache..." : "Analisando dados e gerando insights..."}
          </p>
          <p className="text-sm text-muted-foreground">
            Isso pode levar alguns segundos
          </p>
        </div>
      ) : insights.length === 0 ? (
        <Card className="border-dashed">
          <CardContent className="flex flex-col items-center justify-center py-12">
            <Sparkles className="h-12 w-12 text-muted-foreground/50" />
            <p className="mt-4 text-muted-foreground">
              Nenhum insight disponível
            </p>
            <Button variant="outline" className="mt-4" onClick={handleRefresh}>
              Gerar insights
            </Button>
          </CardContent>
        </Card>
      ) : (
        <>
          <div className="grid gap-4 md:grid-cols-2">
            {insights.map((insight, index) => {
              const config = categoryConfig[insight.category];
              const Icon = config.icon;

              return (
                <Card
                  key={index}
                  className={`border-l-4 ${config.color.split(" ")[2]}`}
                >
                  <CardHeader className="pb-2">
                    <div className="flex items-start justify-between gap-2">
                      <div className="flex items-center gap-2">
                        <div
                          className={`flex h-8 w-8 items-center justify-center rounded-lg ${config.color.split(" ").slice(0, 2).join(" ")}`}
                        >
                          <Icon className="h-4 w-4" />
                        </div>
                        <Badge variant="outline" className={config.color}>
                          {config.label}
                        </Badge>
                      </div>
                      <Badge
                        className={priorityConfig[insight.priority]}
                      >
                        {insight.priority === "high"
                          ? "Alta"
                          : insight.priority === "medium"
                            ? "Média"
                            : "Baixa"}
                      </Badge>
                    </div>
                    <CardTitle className="text-base mt-2">{insight.title}</CardTitle>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    <CardDescription className="text-sm leading-relaxed">
                      {insight.description}
                    </CardDescription>
                    <div className="rounded-lg bg-muted/50 p-3">
                      <p className="text-xs font-medium text-muted-foreground uppercase tracking-wide mb-1">
                        Ação Recomendada
                      </p>
                      <p className="text-sm">{insight.action}</p>
                    </div>
                  </CardContent>
                </Card>
              );
            })}
          </div>

          {/* Cache info footer */}
          {fromCache && (
            <p className="text-xs text-muted-foreground text-center">
              💡 Insights carregados do cache para economia de créditos AI. 
              {dataChanged 
                ? " Clique em 'Atualizar Insights' para gerar novos com os dados mais recentes."
                : ` Próxima atualização disponível em ${formatCooldown(cooldownRemaining)}.`}
            </p>
          )}
        </>
      )}
    </div>
  );
}
