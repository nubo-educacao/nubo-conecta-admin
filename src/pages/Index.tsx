import { useState, useCallback, useMemo } from "react";
import { Link, useLocation } from "react-router-dom";
import { MessageSquare, Heart } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { DashboardHeader } from "@/components/analytics/DashboardHeader";
import { StatCard } from "@/components/analytics/StatCard";
import { PowerUsersCard } from "@/components/analytics/PowerUsersCard";
import { TotalUsersCard } from "@/components/analytics/TotalUsersCard";
import { ActivityChart } from "@/components/analytics/ActivityChart";
import { TopUsersChart } from "@/components/analytics/TopUsersChart";
import { GlobalFunnelSection } from "@/components/analytics/GlobalFunnelSection";
import { useDashboardStats } from "@/hooks/useAnalyticsData";
import { ActionCenter } from "@/components/action-center/ActionCenter";
import { Skeleton } from "@/components/ui/skeleton";
import { DateRangeValue } from "@/components/analytics/DateRangeFilter";
import { useAttributionUrlState } from "@/components/filters/AttributionUrlFilter";

import { commandCenterDateRange } from '@/lib/commandCenterDateRange';
import { hasAttributionFilter } from '@/lib/attributionFilter';
import { attributionArg } from '@/lib/commandCenterAttribution';

const Index = () => {
  const [selectedRange, setSelectedRange] = useState<DateRangeValue>("7d");
  const [lastUpdate, setLastUpdate] = useState<Date>(new Date());
  const [isRefreshing, setIsRefreshing] = useState(false);
  
  const queryClient = useQueryClient();
  const [customDate, setCustomDate] = useState<Date>();
  const dateRange = useMemo(() => commandCenterDateRange(selectedRange, lastUpdate, customDate), [selectedRange, lastUpdate, customDate]);
  const funnelRange = dateRange.from && dateRange.to ? { from: dateRange.from, to: dateRange.to } : null;

  // Recorte por campanha/divulgador (first-touch, TP-7). Mora na URL com as
  // mesmas chaves de Estudantes/Inscrições, para o link ser compartilhável, e
  // chega aos painéis de pessoas e ao funil. A Central de Ações não é por pessoa.
  const [attribution, setAttribution] = useAttributionUrlState();
  // O link para Analytics leva o recorte junto (mesmas chaves de URL).
  const { search } = useLocation();
  const attributionActive = hasAttributionFilter(attribution);

  const { data: stats, isLoading: statsLoading, isError: statsError } = useDashboardStats(dateRange, ...attributionArg(attribution));

  const handleRefresh = useCallback(async () => {
    setIsRefreshing(true);
    try {
      await queryClient.invalidateQueries();
      setLastUpdate(new Date());
    } finally {
      setIsRefreshing(false);
    }
  }, [queryClient]);

  const handleRangeChange = useCallback((range: DateRangeValue) => {
    setSelectedRange(range);
    setLastUpdate(new Date());
  }, []);

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader
        selectedRange={selectedRange}
        onRangeChange={handleRangeChange} onCustomDateChange={setCustomDate}
        onRefresh={handleRefresh}
        isRefreshing={isRefreshing}
        lastUpdate={lastUpdate}
        attribution={attribution}
        onAttributionChange={setAttribution}
      />

      <main className="container py-4 sm:py-6 space-y-4 sm:space-y-6 px-3 sm:px-4 lg:px-8">
        {/* Stats Overview */}
        <section className="grid grid-cols-2 gap-3 sm:gap-4 lg:grid-cols-4">
          {statsLoading ? (
            <>
              {[...Array(4)].map((_, i) => (
                <Skeleton key={i} className="h-32 sm:h-40 w-full" />
              ))}
            </>
          ) : (
            <>
              {statsError || !stats ? <StatCard title="Usuários Cadastrados" value="Indisponível" icon={MessageSquare} /> : <TotalUsersCard
                totalRegistered={stats?.totalRegistered || 0}
                activeUsers={stats?.activeUsers || 0}
                activeWithMessages={stats?.activeUsersWithMessages || 0}
                catalogUsers={stats?.catalogUsers || 0}
                activeChange={stats?.activeUsersChange}
              />}
              {statsError || !stats ? <StatCard title="Power Users" value="Indisponível" icon={MessageSquare} /> : <PowerUsersCard
                count={stats?.powerUsers || 0}
                change={stats?.powerUsersChange}
                powerUsersList={stats?.powerUsersList || []}
                dateRange={dateRange}
              />}
              <StatCard
                title="Total de Mensagens"
                value={statsError ? "Indisponível" : stats?.totalMessages?.toLocaleString() ?? "Indisponível"}
                change={statsError ? undefined : stats?.messagesChange}
                icon={MessageSquare}
                variant="default"
                tooltip="Mensagens enviadas por usuários no período selecionado. Exclui mensagens do sistema e do assistente; a comparação usa o período anterior de mesma duração."
              />
              <StatCard
                title="Favoritos Salvos"
                value={statsError ? "Indisponível" : stats?.totalFavorites?.toLocaleString() ?? "Indisponível"}
                change={statsError ? undefined : stats?.favoritesChange}
                icon={Heart}
                variant="success"
                tooltip="Favoritos ainda salvos que foram criados no período selecionado. Exclusões posteriores não são um histórico de eventos."
              />
            </>
          )}
        </section>

        <p className="text-sm text-muted-foreground">O período filtra mensagens, atividade, recorrência, favoritos, top usuários e o funil global. Cadastros totais mostram o estado atual. NSM, L1, L2, Saúde do Match, demografia, interesse por cliques, cursos, preferências e localização estão em <Link to={{ pathname: "/analytics", search }} className="font-medium text-primary underline-offset-4 hover:underline">Analytics de Produto</Link>.</p>
        {attributionActive && <p className="text-sm text-muted-foreground">Recorte por campanha/divulgador (first-touch) aplicado a cadastros, mensagens, atividade, top usuários e funil global.</p>}
        {statsError && <p role="alert" className="text-sm text-destructive">Não foi possível carregar os indicadores. Use Atualizar para tentar novamente.</p>}

        {/* Action Center */}
        <ActionCenter />

        {/* Atividade e Top usuários — os demais gráficos estão em Analytics de Produto */}
        <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
          <ActivityChart key={`${dateRange.from?.toISOString()}-${dateRange.to?.toISOString()}`} dateRange={dateRange} attribution={attribution} />
          <TopUsersChart dateRange={dateRange} attribution={attribution} />
        </section>

        {/* Funil global (TP-E): mesmo período e recorte first-touch do Command Center */}
        <GlobalFunnelSection range={funnelRange} attribution={attribution} />
      </main>

      {/* Footer */}
      <footer className="border-t border-border bg-card/50 mt-6 sm:mt-8">
        <div className="container py-4 sm:py-6 px-3 sm:px-4 lg:px-8">
          <p className="text-center text-xs sm:text-sm text-muted-foreground">
            Nubo Conecta · Command Center © 2026
          </p>
        </div>
      </footer>
    </div>
  );
};

export default Index;
