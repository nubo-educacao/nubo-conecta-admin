import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Cell,
} from "recharts";
import { useTopCourses } from "@/hooks/useAnalyticsData";
import { Skeleton } from "@/components/ui/skeleton";
import { GraduationCap } from "lucide-react";

const colors = [
  "hsl(199, 89%, 48%)",
  "hsl(217, 91%, 60%)",
  "hsl(142, 71%, 45%)",
  "hsl(38, 92%, 50%)",
  "hsl(280, 87%, 65%)",
  "hsl(199, 89%, 68%)",
  "hsl(340, 82%, 52%)",
  "hsl(160, 84%, 39%)",
  "hsl(45, 93%, 47%)",
  "hsl(262, 83%, 58%)",
];

export function TopCoursesChart() {
  const { data, isLoading, error } = useTopCourses();

  if (isLoading) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Cursos Mais Buscados</h3>
          <p className="text-sm text-muted-foreground">
            Top 20 cursos com maior interesse
          </p>
        </div>
        <Skeleton className="h-[700px] w-full" />
      </div>
    );
  }

  // Normalize data - use searches or buscas field
  const normalizedData = data?.map(item => ({
    ...item,
    buscas: item.buscas ?? item.searches ?? 0
  })) || [];

  const hasData = normalizedData.length > 0 && normalizedData.some(d => d.buscas > 0);

  if (error || !hasData) {
    return (
      <div className="chart-container">
        <div className="mb-6 flex flex-col gap-1">
          <h3 className="text-lg font-semibold font-display">Cursos Mais Buscados</h3>
          <p className="text-sm text-muted-foreground">
            Top 20 cursos com maior interesse
          </p>
        </div>
        <div className="flex flex-col items-center justify-center h-[700px] text-muted-foreground">
          <GraduationCap className="h-12 w-12 mb-4 opacity-50" />
          <p>Nenhum interesse de curso registrado</p>
        </div>
      </div>
    );
  }

  return (
    <div className="chart-container">
      <div className="mb-6 flex flex-col gap-1">
        <h3 className="text-lg font-semibold font-display">Cursos Mais Buscados</h3>
        <p className="text-sm text-muted-foreground">
          Top {normalizedData.length} cursos com maior interesse
        </p>
      </div>
      
      <div className="h-[700px] w-full">
        <ResponsiveContainer width="100%" height="100%">
          <BarChart
            data={normalizedData}
            layout="vertical"
            margin={{ top: 0, right: 20, left: 0, bottom: 0 }}
          >
            <CartesianGrid strokeDasharray="3 3" horizontal={false} className="stroke-border" />
            <XAxis
              type="number"
              tick={{ fontSize: 12 }}
              tickLine={false}
              axisLine={false}
              className="text-muted-foreground"
            />
            <YAxis
              type="category"
              dataKey="name"
              tick={{ fontSize: 12 }}
              tickLine={false}
              axisLine={false}
              width={100}
              className="text-muted-foreground"
            />
            <Tooltip
              contentStyle={{
                backgroundColor: "hsl(var(--card))",
                border: "1px solid hsl(var(--border))",
                borderRadius: "0.75rem",
                boxShadow: "var(--shadow-lg)",
              }}
              cursor={{ fill: "hsl(var(--muted))", opacity: 0.3 }}
              formatter={(value: number) => [value, "Interessados"]}
            />
            <Bar dataKey="buscas" radius={[0, 6, 6, 0]} name="Buscas">
              {normalizedData.map((_, index) => (
                <Cell key={`cell-${index}`} fill={colors[index % colors.length]} />
              ))}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
