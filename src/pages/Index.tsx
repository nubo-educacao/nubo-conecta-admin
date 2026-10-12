import { useState, useCallback, useMemo } from "react";
import { MessageSquare, Heart, TrendingUp, Clock, MapPin } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { DashboardHeader } from "@/components/analytics/DashboardHeader";
import { StatCard } from "@/components/analytics/StatCard";
import { PowerUsersCard } from "@/components/analytics/PowerUsersCard";
import { TotalUsersCard } from "@/components/analytics/TotalUsersCard";
import { ActivityChart } from "@/components/analytics/ActivityChart";
import { TopCoursesChart } from "@/components/analytics/TopCoursesChart";
import { MatchHealthChart } from "@/components/analytics/MatchHealthChart";
import { DemographicsCharts } from "@/components/analytics/DemographicsCharts";
import { LocationPreferenceChart } from "@/components/analytics/LocationPreferenceChart";
import { TopUsersChart } from "@/components/analytics/TopUsersChart";
import { LocationChart } from "@/components/analytics/LocationChart";
import { useDashboardStats } from "@/hooks/useAnalyticsData";
import { ActionCenter } from "@/components/action-center/ActionCenter";
import { Skeleton } from "@/components/ui/skeleton";
import { DateRangeValue } from "@/components/analytics/DateRangeFilter";

import { OpportunityInterestChart } from '@/components/analytics/OpportunityInterestChart';
import { UserPreferencesChart } from '@/components/analytics/UserPreferencesChart';
import { commandCenterDateRange } from '@/lib/commandCenterDateRange';

const Index = () => {
  const [selectedRange, setSelectedRange] = useState<DateRangeValue>("7d");
  const [lastUpdate, setLastUpdate] = useState<Date>(new Date());
  const [isRefreshing, setIsRefreshing] = useState(false);
  
  const queryClient = useQueryClient();
  const [customDate, setCustomDate] = useState<Date>();
  const dateRange = useMemo(() => commandCenterDateRange(selectedRange, lastUpdate, customDate), [selectedRange, lastUpdate, customDate]);
  const { data: stats, isLoading: statsLoading, isError: statsError } = useDashboardStats(dateRange);

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

        <p className="text-sm text-muted-foreground">O período filtra mensagens, atividade, recorrência, favoritos e cliques. Cadastros totais, Match, demografia e preferências mostram o estado atual dos perfis, sem filtro de período.</p>
        {statsError && <p role="alert" className="text-sm text-destructive">Não foi possível carregar os indicadores. Use Atualizar para tentar novamente.</p>}

        {/* Action Center */}
        <ActionCenter />

        {/* Charts Row 1 */}
        <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
          <ActivityChart key={`${dateRange.from?.toISOString()}-${dateRange.to?.toISOString()}`} dateRange={dateRange} />
          <MatchHealthChart />
        </section>

        {/* Charts Row 2 - Rankings */}
        <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
          <TopUsersChart dateRange={dateRange} />
          <TopCoursesChart />
        </section>

        {/* Interesse observado e declarado */}
        <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
          <OpportunityInterestChart dateRange={dateRange} />
          <UserPreferencesChart />
        </section>

        {/* Charts Row 3 - Location */}
        <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
          <LocationChart />
          <LocationPreferenceChart />
        </section>

        {/* Charts Row 5 - Demografia (TP-1 1B) */}
        <DemographicsCharts />

        {/* Quick Insights */}
        <section className="grid grid-cols-1 gap-3 sm:gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div className="stat-card">
            <div className="flex items-center gap-3 mb-3">
              <div className="rounded-lg bg-success/10 p-2">
                <TrendingUp className="h-4 w-4 text-success" />
              </div>
              <h4 className="font-semibold text-sm sm:text-base">Dados em Tempo Real</h4>
            </div>
            <p className="text-xs sm:text-sm text-muted-foreground">
              Clique em <span className="font-semibold text-foreground">atualizar</span> para ver os dados mais recentes.
              Métricas temporais usam o período selecionado.
            </p>
          </div>

          <div className="stat-card">
            <div className="flex items-center gap-3 mb-3">
              <div className="rounded-lg bg-warning/10 p-2">
                <Clock className="h-4 w-4 text-warning" />
              </div>
              <h4 className="font-semibold text-sm sm:text-base">Período de Análise</h4>
            </div>
            <p className="text-xs sm:text-sm text-muted-foreground">
              Comparações são feitas entre o <span className="font-semibold text-foreground">período selecionado</span> e o
              período anterior de mesma duração para identificar tendências.
            </p>
          </div>

          <div className="stat-card sm:col-span-2 lg:col-span-1">
            <div className="flex items-center gap-3 mb-3">
              <div className="rounded-lg bg-primary/10 p-2">
                <MapPin className="h-4 w-4 text-primary" />
              </div>
              <h4 className="font-semibold text-sm sm:text-base">Conectado ao Supabase</h4>
            </div>
            <p className="text-xs sm:text-sm text-muted-foreground">
              Dashboard conectado ao <span className="font-semibold text-foreground">ambiente configurado</span> com
              dados reais da plataforma Cloudinha.
            </p>
          </div>
        </section>
      </main>

      {/* Footer */}
      <footer className="border-t border-border bg-card/50 mt-6 sm:mt-8">
        <div className="container py-4 sm:py-6 px-3 sm:px-4 lg:px-8">
          <p className="text-center text-xs sm:text-sm text-muted-foreground">
            Cloudinha Analytics · Nubo Educação © 2026
          </p>
        </div>
      </footer>
    </div>
  );
};

export default Index;
