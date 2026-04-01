
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { SeanEllisStats } from "@/services/seanEllisService";
import { Loader2 } from "lucide-react";
import {
    PieChart,
    Pie,
    Cell,
    Tooltip,
    ResponsiveContainer,
    Legend
} from "recharts";

interface SeanEllisStatsProps {
    stats: SeanEllisStats | undefined;
    isLoading: boolean;
}

const PMF_COLORS: Record<string, string> = {
    "Muito desapontado(a)": "#4ade80", // Green
    "Um pouco desapontado(a)": "#fde047", // Yellow
    "Nada desapontado(a) (não faria diferença)": "#f87171", // Red
};

const DEFAULT_COLOR = "#e2e8f0";

const renderCustomizedLabel = ({ cx, cy, midAngle, innerRadius, outerRadius, percent }: any) => {
    const radius = innerRadius + (outerRadius - innerRadius) * 0.5;
    const x = cx + radius * Math.cos(-midAngle * (Math.PI / 180));
    const y = cy + radius * Math.sin(-midAngle * (Math.PI / 180));

    return (
        <text
            x={x}
            y={y}
            fill="black"
            textAnchor="middle"
            dominantBaseline="central"
            className="text-xs font-bold"
        >
            {`${(percent * 100).toFixed(1)}%`}
        </text>
    );
};

export function SeanEllisStatsDisplay({ stats, isLoading }: SeanEllisStatsProps) {
    if (isLoading) {
        return (
            <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
                {[1, 2, 3].map((i) => (
                    <Card key={i}>
                        <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                            <CardTitle className="text-sm font-medium">Loading...</CardTitle>
                        </CardHeader>
                        <CardContent>
                            <Loader2 className="h-4 w-4 animate-spin" />
                        </CardContent>
                    </Card>
                ))}
            </div>
        );
    }

    if (!stats) return null;

    // Define a specific order for the slices to match the reference look
    const sliceOrder = [
        "Um pouco desapontado(a)",
        "Nada desapontado(a) (não faria diferença)",
        "Muito desapontado(a)"
    ];

    const distribution = stats.disappointment_distribution || {};
    const pieData = sliceOrder
        .filter(name => distribution[name] !== undefined)
        .map(name => ({
            name,
            value: distribution[name]
        }));

    // Add any categories not in the sliceOrder at the end
    Object.keys(distribution).forEach(name => {
        if (!sliceOrder.includes(name)) {
            pieData.push({ name, value: distribution[name] });
        }
    });

    return (
        <div className="grid gap-4 md:grid-cols-3">
            {/* Graph Section - Takes 2/3 (col-span-2) */}
            <Card className="col-span-2">
                <CardContent className="h-[250px] p-0 flex items-center justify-center">
                    <ResponsiveContainer width="100%" height="100%">
                        <PieChart>
                            <Pie
                                data={pieData}
                                cx="45%"
                                cy="50%"
                                labelLine={false}
                                label={renderCustomizedLabel}
                                outerRadius={85}
                                dataKey="value"
                                paddingAngle={3}
                                stroke="none"
                            >
                                {pieData.map((entry, index) => (
                                    <Cell
                                        key={`cell-${index}`}
                                        fill={PMF_COLORS[entry.name] || DEFAULT_COLOR}
                                    />
                                ))}
                            </Pie>
                            <Tooltip />
                            <Legend
                                layout="vertical"
                                align="right"
                                verticalAlign="middle"
                                iconType="circle"
                                iconSize={8}
                                wrapperStyle={{
                                    paddingLeft: "10px",
                                    fontSize: "11px",
                                    lineHeight: "14px"
                                }}
                            />
                        </PieChart>
                    </ResponsiveContainer>
                </CardContent>
            </Card>

            {/* Stats Section - Takes 1/3 (col-span-1) */}
            <div className="space-y-4 col-span-1">
                <Card>
                    <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                        <CardTitle className="text-sm font-medium">
                            Total de Respondentes
                        </CardTitle>
                    </CardHeader>
                    <CardContent>
                        <div className="text-xl font-bold">{stats.total_respondents}</div>
                    </CardContent>
                </Card>
                <Card>
                    <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                        <CardTitle className="text-sm font-medium">
                            Usuários Identificados
                        </CardTitle>
                    </CardHeader>
                    <CardContent>
                        <div className="text-xl font-bold">{stats.total_identified_users}</div>
                        <p className="text-[10px] text-muted-foreground">
                            {stats.total_respondents > 0 ? ((stats.total_identified_users / stats.total_respondents) * 100).toFixed(1) : 0}% do total
                        </p>
                    </CardContent>
                </Card>
            </div>
        </div>
    );
}
