import { PieChart, Pie, Cell, ResponsiveContainer, Tooltip } from "recharts";
import { useUserPreferences } from "@/hooks/useAnalyticsData";
import { Skeleton } from "@/components/ui/skeleton";
import { PieChartIcon } from "lucide-react";

const defaultColors = [
  "hsl(199, 89%, 48%)",
  "hsl(217, 91%, 60%)",
  "hsl(142, 71%, 45%)",
  "hsl(38, 92%, 50%)",
  "hsl(280, 87%, 65%)",
];

export function UserPreferencesChart() {
  const { data, isLoading, error } = useUserPreferences();

  if (isLoading) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Preferências de Acesso</h3>
          <p className="text-sm text-muted-foreground">
            Distribuição por tipo de ingresso
          </p>
        </div>
        <Skeleton className="h-[250px] w-full" />
      </div>
    );
  }

  if (error || !data || data.length === 0) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Preferências de Acesso</h3>
          <p className="text-sm text-muted-foreground">
            Distribuição por tipo de ingresso
          </p>
        </div>
        <div className="flex flex-col items-center justify-center h-[250px] text-muted-foreground">
          <PieChartIcon className="h-12 w-12 mb-4 opacity-50" />
          <p>Nenhuma preferência registrada</p>
        </div>
      </div>
    );
  }

  return (
    <div className="chart-container">
      <div className="mb-6 flex flex-col gap-1">
        <h3 className="text-lg font-semibold font-display">Preferências de Acesso</h3>
        <p className="text-sm text-muted-foreground">
          Distribuição por tipo de ingresso
        </p>
      </div>

      <div className="h-[250px] w-full">
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie
              data={data}
              cx="50%"
              cy="50%"
              innerRadius={60}
              outerRadius={90}
              paddingAngle={4}
              dataKey="value"
            >
              {data.map((entry, index) => (
                <Cell key={`cell-${index}`} fill={entry.color || defaultColors[index % defaultColors.length]} />
              ))}
            </Pie>
            <Tooltip
              contentStyle={{
                backgroundColor: "hsl(var(--card))",
                border: "1px solid hsl(var(--border))",
                borderRadius: "0.75rem",
                boxShadow: "var(--shadow-lg)",
              }}
              formatter={(value: number) => [`${value}%`, "Percentual"]}
            />
          </PieChart>
        </ResponsiveContainer>
      </div>

      <div className="mt-4 grid grid-cols-2 gap-2">
        {data.map((item, index) => (
          <div key={item.name} className="flex items-center gap-2">
            <div
              className="h-3 w-3 rounded-full"
              style={{ backgroundColor: item.color || defaultColors[index % defaultColors.length] }}
            />
            <span className="text-sm text-muted-foreground">{item.name}</span>
            <span className="text-sm font-semibold ml-auto">{item.value}%</span>
          </div>
        ))}
      </div>
    </div>
  );
}
