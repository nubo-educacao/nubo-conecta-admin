import { useState } from "react";
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { Skeleton } from "@/components/ui/skeleton";
import { BarChart3, ZoomOut } from "lucide-react";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import type { DateRange } from "@/lib/analytics-queries";
import { Button } from "@/components/ui/button";
import type { AttributionFilter } from "@/lib/attributionFilter";
import { attributionEdgeBody, attributionQueryKey } from "@/lib/commandCenterAttribution";

type ViewMode = "week" | "day" | "total";

interface ActivityData {
  label: string;
  mensagens: number;
  usuarios: number;
}

async function fetchActivityByMode(mode: ViewMode, zoomHour: number | null, dateRange?: DateRange, attribution?: AttributionFilter): Promise<ActivityData[]> {
  const { data, error } = await supabase.functions.invoke('analytics-activity', {
    body: { mode, dateRange, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone, ...(zoomHour !== null && { zoomHour }), ...attributionEdgeBody(attribution) }
  });
  
  if (error) throw error;
  return data;
}

// Por dia num período de 90 dias são 90 rótulos: com intervalo 0 eles se
// sobrepõem. "preserveStartEnd" deixa o recharts escolher os que cabem, sempre
// com o primeiro e o último. Por hora (24 pontos) fica de 3 em 3; o zoom de 15
// minutos (4 pontos) mostra todos.
export function activityXAxisInterval(mode: ViewMode, zoomHour: number | null): number | "preserveStartEnd" {
  if (zoomHour !== null) return 0;
  return mode === "day" ? 2 : "preserveStartEnd";
}

export function ActivityChart({ dateRange, attribution }: { dateRange?: DateRange; attribution?: AttributionFilter }) {
  const [viewMode, setViewMode] = useState<ViewMode>("week");
  const [zoomHour, setZoomHour] = useState<number | null>(null);
  
  const { data, isLoading, error } = useQuery({
    queryKey: ["activity-data", viewMode, zoomHour, dateRange, attributionQueryKey(attribution)],
    queryFn: () => fetchActivityByMode(viewMode, zoomHour, dateRange, attribution),
    staleTime: 1000 * 60 * 5,
  });

  const handleBarClick = (data: ActivityData) => {
    if (viewMode === "day" && zoomHour === null && data.label.endsWith('h')) {
      // Extract hour from label like "20h" -> 20
      const hour = parseInt(data.label.replace('h', ''), 10);
      if (!isNaN(hour)) {
        setZoomHour(hour);
      }
    }
  };

  const handleZoomOut = () => {
    setZoomHour(null);
  };

  if (isLoading) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex items-center justify-between">
          <div className="flex flex-col gap-1">
            <h3 className="text-lg font-semibold font-display">Atividade</h3>
            <p className="text-sm text-muted-foreground">
              Mensagens e usuários ativos
            </p>
          </div>
        </div>
        <Skeleton className="h-[300px] w-full" />
      </div>
    );
  }

  if (error || !data) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex items-center justify-between">
          <div className="flex flex-col gap-1">
            <h3 className="text-lg font-semibold font-display">Atividade</h3>
            <p className="text-sm text-muted-foreground">
              Mensagens e usuários ativos
            </p>
          </div>
        </div>
        <div className="flex flex-col items-center justify-center h-[300px] text-muted-foreground">
          <BarChart3 className="h-12 w-12 mb-4 opacity-50" />
          <p role={error ? "alert" : undefined}>{error ? "Não foi possível carregar a atividade." : "Atividade indisponível."}</p>
        </div>
      </div>
    );
  }

  const getSubtitle = () => {
    if (zoomHour !== null) return `Mensagens de usuários às ${zoomHour.toString().padStart(2, "0")}h · intervalos de 15 minutos no período`;
    if (dateRange) return viewMode === "day" ? "Mensagens de usuários por hora — soma no período selecionado" : "Mensagens de usuários por dia no período selecionado";
    if (viewMode === "total") {
      return "Histórico completo de atividade por dia";
    }
    if (viewMode === "week") {
      return "Mensagens e usuários por dia da semana";
    }
    if (zoomHour !== null) {
      return `Detalhes das ${zoomHour.toString().padStart(2, '0')}h às ${(zoomHour + 1).toString().padStart(2, '0')}h (15 em 15 min)`;
    }
    return "Mensagens e usuários hora a hora (clique para detalhar)";
  };

  return (
    <div className="chart-container">
      <div className="mb-6 flex items-center justify-between">
        <div className="flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Atividade</h3>
          <p className="text-sm text-muted-foreground">
            {getSubtitle()}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {zoomHour !== null && (
            <Button
              variant="outline"
              size="sm"
              onClick={handleZoomOut}
              className="gap-1"
            >
              <ZoomOut className="h-4 w-4" />
              Voltar
            </Button>
          )}
          <ToggleGroup 
            type="single" 
            value={viewMode} 
            onValueChange={(value) => {
              if (value) {
                setViewMode(value as ViewMode);
                setZoomHour(null);
              }
            }}
            className="bg-muted rounded-lg p-1"
          >
            <ToggleGroupItem 
              value="week" 
              size="sm"
              className="data-[state=on]:bg-background data-[state=on]:text-foreground data-[state=on]:shadow-sm px-3"
            >
              {dateRange ? "Por dia" : "Semana"}
            </ToggleGroupItem>
            <ToggleGroupItem 
              value="day" 
              size="sm"
              className="data-[state=on]:bg-background data-[state=on]:text-foreground data-[state=on]:shadow-sm px-3"
            >
              {dateRange ? "Por hora" : "Hoje"}
            </ToggleGroupItem>
            <ToggleGroupItem 
              value="total" 
              size="sm"
              className="data-[state=on]:bg-background data-[state=on]:text-foreground data-[state=on]:shadow-sm px-3"
            >
              Total
            </ToggleGroupItem>
          </ToggleGroup>
        </div>
      </div>
      
      {data.every(row => row.mensagens === 0) && <p className="text-sm text-muted-foreground">Nenhuma mensagem de usuário no período selecionado.</p>}
      <div className="h-[300px] w-full">
        <ResponsiveContainer width="100%" height="100%">
          <AreaChart
            data={data}
            margin={{ top: 10, right: 10, left: -20, bottom: 0 }}
            onClick={(e) => {
              if (e && e.activePayload && e.activePayload[0]) {
                handleBarClick(e.activePayload[0].payload);
              }
            }}
            style={{ cursor: viewMode === "day" && zoomHour === null ? 'pointer' : 'default' }}
          >
            <defs>
              <linearGradient id="colorMensagens" x1="0" y1="0" x2="0" y2="1">
                <stop offset="5%" stopColor="hsl(199, 89%, 48%)" stopOpacity={0.3} />
                <stop offset="95%" stopColor="hsl(199, 89%, 48%)" stopOpacity={0} />
              </linearGradient>
              <linearGradient id="colorUsuarios" x1="0" y1="0" x2="0" y2="1">
                <stop offset="5%" stopColor="hsl(217, 91%, 60%)" stopOpacity={0.3} />
                <stop offset="95%" stopColor="hsl(217, 91%, 60%)" stopOpacity={0} />
              </linearGradient>
            </defs>
            <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
            <XAxis
              dataKey="label"
              tick={{ fontSize: 12 }}
              tickLine={false}
              axisLine={false}
              className="text-muted-foreground"
              interval={activityXAxisInterval(viewMode, zoomHour)}
              minTickGap={16}
            />
            <YAxis
              tick={{ fontSize: 12 }}
              tickLine={false}
              axisLine={false}
              className="text-muted-foreground"
            />
            <Tooltip
              contentStyle={{
                backgroundColor: "hsl(var(--card))",
                border: "1px solid hsl(var(--border))",
                borderRadius: "0.75rem",
                boxShadow: "var(--shadow-lg)",
              }}
              labelStyle={{ fontWeight: 600 }}
            />
            <Area
              type="monotone"
              dataKey="mensagens"
              stroke="hsl(199, 89%, 48%)"
              strokeWidth={2}
              fillOpacity={1}
              fill="url(#colorMensagens)"
              name="Mensagens"
            />
            <Area
              type="monotone"
              dataKey="usuarios"
              stroke="hsl(217, 91%, 60%)"
              strokeWidth={2}
              fillOpacity={1}
              fill="url(#colorUsuarios)"
              name="Usuários"
            />
          </AreaChart>
        </ResponsiveContainer>
      </div>
      
      <div className="mt-4 flex items-center justify-center gap-6">
        <div className="flex items-center gap-2">
          <div className="h-3 w-3 rounded-full bg-primary" />
          <span className="text-sm text-muted-foreground">Mensagens</span>
        </div>
        <div className="flex items-center gap-2">
          <div className="h-3 w-3 rounded-full bg-chart-2" />
          <span className="text-sm text-muted-foreground">Usuários</span>
        </div>
      </div>
    </div>
  );
}
