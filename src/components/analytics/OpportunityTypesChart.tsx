import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { 
  BarChart, 
  Bar, 
  XAxis, 
  YAxis, 
  Tooltip, 
  ResponsiveContainer, 
  Cell 
} from "recharts";
import { Heart, Sparkles, TrendingUp, AlertTriangle, Users } from "lucide-react";
import { useOpportunityTypes } from "@/hooks/useAnalyticsData";

const COLORS = {
  sisu: "hsl(var(--chart-1))",
  prouni: "hsl(var(--chart-5))",
  ambos: "hsl(var(--chart-3))",
  default: "hsl(var(--muted-foreground))",
};

export function OpportunityTypesChart() {
  const { data, isLoading, error } = useOpportunityTypes();

  if (isLoading) {
    return (
      <Card className="h-full">
        <CardHeader>
          <Skeleton className="h-6 w-48" />
        </CardHeader>
        <CardContent>
          <Skeleton className="h-[300px] w-full" />
        </CardContent>
      </Card>
    );
  }

  if (error || !data) {
    return (
      <Card className="h-full">
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-lg">
            <Heart className="h-5 w-5 text-primary" />
            Oportunidades Buscadas
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col items-center justify-center h-[300px] text-muted-foreground">
          <Heart className="h-12 w-12 mb-4 opacity-50" />
          <p className="text-sm">Erro ao carregar dados</p>
        </CardContent>
      </Card>
    );
  }

  const getBarColor = (name: string) => {
    const nameLower = name.toLowerCase();
    if (nameLower.includes('sisu')) return COLORS.sisu;
    if (nameLower.includes('prouni')) return COLORS.prouni;
    if (nameLower.includes('ambos')) return COLORS.ambos;
    return COLORS.default;
  };

  const savedOpportunities = data.savedOpportunities ?? { byType: [], total: 0, withVagasOciosas: 0 };
  const programPreferences = data.programPreferences ?? [];
  const vagasOciosas = data.vagasOciosas ?? { total: 0, byModality: [] };
  const conversionInsight = data.conversionInsight ?? { interestedInSisu: 0, savedSisu: 0 };

  // Calculate conversion rate
  const sisuConversionRate = conversionInsight.interestedInSisu > 0 
    ? Math.round((conversionInsight.savedSisu / conversionInsight.interestedInSisu) * 100) 
    : 0;

  return (
    <Card className="h-full">
      <CardHeader className="pb-2">
        <CardTitle className="flex items-center justify-between text-lg">
          <div className="flex items-center gap-2">
            <Heart className="h-5 w-5 text-primary" />
            Oportunidades Buscadas
          </div>
          <Badge variant="outline" className="text-xs font-normal">
            Comportamento dos Jovens
          </Badge>
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        {/* Seção Principal: Favoritos Salvos */}
        <div className="rounded-lg bg-primary/5 border border-primary/20 p-4">
          <div className="flex items-center gap-2 mb-3">
            <Heart className="h-4 w-4 text-primary" />
            <p className="text-sm font-medium">Oportunidades Salvas pelos Jovens</p>
          </div>
          
          {savedOpportunities.total > 0 ? (
            <>
              <div className="grid grid-cols-2 gap-3 mb-3">
                {savedOpportunities.byType.map((item) => (
                  <div 
                    key={item.type} 
                    className="text-center p-3 rounded-lg bg-background border"
                  >
                    <div className="flex items-center justify-center gap-1.5 mb-1">
                      <div 
                        className="w-2 h-2 rounded-full" 
                        style={{ backgroundColor: getBarColor(item.type) }} 
                      />
                      <span className="text-xs text-muted-foreground">{item.type}</span>
                    </div>
                    <p className="text-xl font-bold">{item.count}</p>
                    <p className="text-xs text-muted-foreground flex items-center justify-center gap-1">
                      <Users className="h-3 w-3" />
                      {item.uniqueUsers} {item.uniqueUsers === 1 ? 'usuário' : 'usuários'}
                    </p>
                  </div>
                ))}
              </div>

              {/* Insight de Vagas Ociosas nos favoritos */}
              {savedOpportunities.withVagasOciosas > 0 && (
                <div className="flex items-center gap-2 p-2 rounded-md bg-success/10 border border-success/20">
                  <Sparkles className="h-4 w-4 text-success" />
                  <p className="text-xs text-success">
                    <strong>{savedOpportunities.withVagasOciosas}</strong> favoritos têm vagas ociosas disponíveis!
                  </p>
                </div>
              )}
            </>
          ) : (
            <div className="flex flex-col items-center justify-center py-4 text-muted-foreground">
              <Heart className="h-8 w-8 mb-2 opacity-30" />
              <p className="text-sm">Nenhum favorito salvo ainda</p>
            </div>
          )}
        </div>

        {/* Programa de Interesse Declarado */}
        <div>
          <div className="flex items-center justify-between mb-2">
            <p className="text-sm font-medium">Interesse Declarado</p>
            <Badge variant="secondary" className="text-xs">
              {programPreferences.reduce((sum, p) => sum + p.count, 0)} usuários
            </Badge>
          </div>
          
          {programPreferences.length > 0 ? (
            <ResponsiveContainer width="100%" height={100}>
              <BarChart
                data={programPreferences}
                layout="vertical"
                margin={{ top: 0, right: 30, left: 70, bottom: 0 }}
              >
                <XAxis type="number" hide />
                <YAxis 
                  type="category" 
                  dataKey="name" 
                  axisLine={false}
                  tickLine={false}
                  tick={{ fontSize: 11, fill: 'hsl(var(--muted-foreground))' }}
                  width={65}
                />
                <Tooltip
                  formatter={(value: number, name: string, props: { payload: { percentage: number } }) => [
                    `${value} usuários (${props.payload.percentage}%)`,
                    'Interesse'
                  ]}
                  contentStyle={{
                    backgroundColor: 'hsl(var(--popover))',
                    border: '1px solid hsl(var(--border))',
                    borderRadius: '8px',
                    fontSize: '12px',
                  }}
                />
                <Bar dataKey="count" radius={[0, 4, 4, 0]} maxBarSize={20}>
                  {programPreferences.map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={getBarColor(entry.name)} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          ) : (
            <div className="flex items-center justify-center h-[100px] text-muted-foreground text-sm">
              Nenhuma preferência registrada
            </div>
          )}
        </div>

        {/* Insight de Conversão */}
        {conversionInsight.interestedInSisu > 0 && (
          <div className="flex items-start gap-2 p-3 rounded-lg bg-warning/10 border border-warning/20">
            <AlertTriangle className="h-4 w-4 text-warning mt-0.5 shrink-0" />
            <div className="text-xs">
              <p className="font-medium text-warning">Oportunidade de Conversão</p>
              <p className="text-muted-foreground mt-1">
                {conversionInsight.interestedInSisu} usuários interessados em SISU, 
                mas apenas {conversionInsight.savedSisu} salvaram oportunidades 
                ({sisuConversionRate}% conversão)
              </p>
            </div>
          </div>
        )}

        {/* Potencial: Vagas Ociosas Disponíveis */}
        <div className="pt-2 border-t">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Sparkles className="h-4 w-4 text-success" />
              <span className="text-xs text-muted-foreground">Potencial não explorado:</span>
            </div>
            <div className="flex items-center gap-2">
              <span className="text-sm font-bold text-success">
                {vagasOciosas.total.toLocaleString()}
              </span>
              <span className="text-xs text-muted-foreground">vagas ociosas</span>
            </div>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
