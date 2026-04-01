import { useState, useCallback } from "react";
import { MessageSquare, Heart, TrendingUp, Clock, MapPin } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { DashboardHeader } from "@/components/analytics/DashboardHeader";
import { StatCard } from "@/components/analytics/StatCard";
import { PowerUsersCard } from "@/components/analytics/PowerUsersCard";
import { TotalUsersCard } from "@/components/analytics/TotalUsersCard";
import { ActivityChart } from "@/components/analytics/ActivityChart";
import { TopCoursesChart } from "@/components/analytics/TopCoursesChart";
import { OpportunityTypesChart } from "@/components/analytics/OpportunityTypesChart";
import { FlowFunnelChart } from "@/components/analytics/FlowFunnelChart";
import { LocationPreferenceChart } from "@/components/analytics/LocationPreferenceChart";
import { TopUsersChart } from "@/components/analytics/TopUsersChart";
import { LocationChart } from "@/components/analytics/LocationChart";
import { useDashboardStats } from "@/hooks/useAnalyticsData";
import { Skeleton } from "@/components/ui/skeleton";
import { DateRangeValue } from "@/components/analytics/DateRangeFilter";

const Index = () => {
  const [selectedRange, setSelectedRange] = useState<DateRangeValue>("7d");
  const [lastUpdate, setLastUpdate] = useState<Date>(new Date());
  const [isRefreshing, setIsRefreshing] = useState(false);
  
  const queryClient = useQueryClient();
  const { data: stats, isLoading: statsLoading } = useDashboardStats();

  const handleRefresh = useCallback(async () => {
    setIsRefreshing(true);
    await queryClient.invalidateQueries();
    setLastUpdate(new Date());
    setIsRefreshing(false);
  }, [queryClient]);

  const handleRangeChange = useCallback((range: DateRangeValue) => {
    setSelectedRange(range);
    // Re-fetch data when range changes
    queryClient.invalidateQueries();
    setLastUpdate(new Date());
  }, [queryClient]);

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader
        selectedRange={selectedRange}
        onRangeChange={handleRangeChange}
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
              <TotalUsersCard
                totalRegistered={stats?.totalRegistered || 0}
                activeUsers={stats?.activeUsers || 0}
                activeWithMessages={stats?.activeUsersWithMessages || 0}
                catalogUsers={stats?.catalogUsers || 0}
                activeChange={stats?.activeUsersChange}
              />
              <PowerUsersCard
                count={stats?.powerUsers || 0}
                change={stats?.powerUsersChange}
                powerUsersList={stats?.powerUsersList || []}
              />
              <StatCard
                title="Total de Mensagens"
                value={stats?.totalMessages.toLocaleString() || "0"}
                change={stats?.messagesChange}
                icon={MessageSquare}
                variant="default"
                tooltip="Soma de todas as mensagens trocadas no chat (tanto do usuário quanto do assistente)."
              />
              <StatCard
                title="Favoritos Salvos"
                value={stats?.totalFavorites?.toLocaleString() || "0"}
                change={stats?.favoritesChange}
                icon={Heart}
                variant="success"
                tooltip="Total de cursos ou parceiros que os usuários salvaram como favoritos."
              />
            </>
          )}
        </section>

        {/* Charts Row 1 */}
        <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
          <ActivityChart />
          <FlowFunnelChart />
        </section>

        {/* Charts Row 2 - Rankings */}
        <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
          <TopUsersChart />
          <TopCoursesChart />
        </section>

        {/* Charts Row 3 - Opportunities */}
        <section>
          <OpportunityTypesChart />
        </section>

        {/* Charts Row 4 - Location */}
        <section className="grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-2">
          <LocationChart />
          <LocationPreferenceChart />
        </section>

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
              Métricas baseadas nos últimos 7 dias.
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
              Comparações são feitas entre a <span className="font-semibold text-foreground">semana atual</span> e a 
              semana anterior para identificar tendências.
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
              Dashboard conectado ao banco <span className="font-semibold text-foreground">nubo-hub-prod</span> com 
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