import { useLocationData } from "@/hooks/useAnalyticsData";
import { MapPin } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";

const stateColors = [
  "bg-primary", "bg-chart-2", "bg-chart-3", "bg-chart-4", "bg-chart-5", "bg-success", "bg-warning",
];

export function LocationChart() {
  const { data: locations, isLoading, error } = useLocationData();

  if (isLoading) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Ranking de Localização</h3>
          <p className="text-sm text-muted-foreground">Onde os usuários moram</p>
        </div>
        <div className="space-y-3">
          {[...Array(5)].map((_, i) => (
            <Skeleton key={i} className="h-12 w-full" />
          ))}
        </div>
      </div>
    );
  }

  if (error || !locations || locations.length === 0) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Ranking de Localização</h3>
          <p className="text-sm text-muted-foreground">Onde os usuários moram</p>
        </div>
        <div className="flex flex-col items-center justify-center py-12 text-muted-foreground">
          <MapPin className="h-12 w-12 mb-4 opacity-50" />
          <p>Nenhum dado de localização disponível</p>
        </div>
      </div>
    );
  }

  const maxCount = locations[0]?.count ?? 1;
  const total = locations.reduce((sum, loc) => sum + (loc.count ?? 0), 0);
  
  if (total === 0) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Ranking de Localização</h3>
          <p className="text-sm text-muted-foreground">Onde os usuários moram</p>
        </div>
        <div className="flex flex-col items-center justify-center py-12 text-muted-foreground">
          <MapPin className="h-12 w-12 mb-4 opacity-50" />
          <p>Nenhum dado de localização disponível</p>
        </div>
      </div>
    );
  }

  return (
    <div className="chart-container">
      <div className="mb-6 flex flex-col gap-1">
        <h3 className="text-lg font-semibold font-display">Ranking de Localização</h3>
        <p className="text-sm text-muted-foreground">Onde os usuários moram</p>
      </div>

      <div className="space-y-3">
        {locations.map((location, index) => {
          const percentage = (location.count / maxCount) * 100;
          return (
            <div key={`${location.name}-${index}`} className="opacity-0 animate-fade-in" style={{ animationDelay: `${index * 50}ms` }}>
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-2">
                  <div className={cn("h-3 w-3 rounded-full", stateColors[index % stateColors.length])} />
                  <span className="text-sm font-medium">{location.name}</span>
                </div>
                <div className="flex items-center gap-2">
                  <span className="text-sm font-semibold">{location.count}</span>
                  <span className="text-xs text-muted-foreground">({Math.round((location.count / total) * 100)}%)</span>
                </div>
              </div>
              <div className="h-2 w-full rounded-full bg-muted overflow-hidden">
                <div className={cn("h-full rounded-full transition-all duration-500", stateColors[index % stateColors.length])} style={{ width: `${percentage}%` }} />
              </div>
            </div>
          );
        })}
      </div>

      <div className="mt-6 p-4 rounded-lg bg-muted/50 border border-border">
        <p className="text-sm text-muted-foreground">
          <span className="font-semibold text-foreground">Insight:</span> A maior concentração de usuários está em <span className="font-semibold text-foreground">{locations[0]?.name || "N/A"}</span>.
        </p>
      </div>
    </div>
  );
}
