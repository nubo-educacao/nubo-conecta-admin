import React from "react";
import { useQuery } from "@tanstack/react-query";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  PieChart,
  Pie,
  Cell,
  Legend,
  LineChart,
  Line,
  LabelList
} from "recharts";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { getPartnersList } from "@/services/applicationsService";
import {
  getAdminFunnelChart,
  getAdminPassportPhases,
  getAdminFurthestPassportPhases,
  getPartnerFunnel,
  getPartnerApplicationBuckets,
  getStudentApplicationsOverTime,
  getAdminFunnelUsers
} from "@/services/passportDashboardService";
import { Loader2, Download } from "lucide-react";
import { Button } from "@/components/ui/button";
import { toast } from "sonner";

const COLORS = ['#0088FE', '#00C49F', '#FFBB28', '#FF8042', '#8884d8', '#82ca9d'];

const CustomTooltip = ({ active, payload, label }: any) => {
  if (active && payload && payload.length) {
    const data = payload[0].payload;
    return (
      <div className="bg-white p-3 border rounded-md shadow-sm text-sm">
        <p className="font-bold text-gray-700 mb-2">{label}</p>
        {payload.map((entry: any) => (
          <p key={entry.name} style={{ color: entry.color }} className="font-medium">
            {entry.name}: {entry.value}
          </p>
        ))}
        <p className="font-bold text-gray-900 border-t mt-2 pt-2">
          Total: {data.Geral || 0}
        </p>
      </div>
    );
  }
  return null;
};

const CustomDropBadge = (props: any) => {
  const { x, y, width, height, value } = props;
  if (!value) return null;
  return (
    <g>
      <rect x={x + width + 10} y={y + height / 2 - 12} width={42} height={24} fill="#f1f5f9" rx={6} />
      <text x={x + width + 31} y={y + height / 2 + 4} fill="#64748b" fontSize={12} textAnchor="middle" fontWeight="bold">
        {value}
      </text>
    </g>
  );
};

export default function PassportDashboard() {
  const [partnerFilter, setPartnerFilter] = React.useState<string>("all");
  const [daysFilter, setDaysFilter] = React.useState<number | null>(30);
  const [isExporting, setIsExporting] = React.useState(false);

  const { data: partnersData } = useQuery({
    queryKey: ["partnersList"],
    queryFn: getPartnersList,
  });

  const { data: funnelData, isLoading: isLoadingFunnel } = useQuery({
    queryKey: ["adminFunnelChart"],
    queryFn: getAdminFunnelChart,
  });

  const { data: phasesData, isLoading: isLoadingPhases } = useQuery({
    queryKey: ["adminPassportPhases"],
    queryFn: getAdminPassportPhases,
  });

  const { data: furthestPhasesData, isLoading: isLoadingFurthest } = useQuery({
    queryKey: ["adminFurthestPassportPhases"],
    queryFn: getAdminFurthestPassportPhases,
  });

  const { data: partnerFunnelData, isLoading: isLoadingPartnerFunnel } = useQuery({
    queryKey: ["partnerFunnel"],
    queryFn: getPartnerFunnel,
  });

  const { data: bucketsData, isLoading: isLoadingBuckets } = useQuery({
    queryKey: ["partnerApplicationBuckets"],
    queryFn: () => getPartnerApplicationBuckets(), // Fetching all for now
  });

  const { data: overTimeData, isLoading: isLoadingOverTime } = useQuery({
    queryKey: ["studentApplicationsOverTime", partnerFilter, daysFilter],
    queryFn: () => getStudentApplicationsOverTime(partnerFilter, daysFilter),
  });

  const currentPartnersInChart = React.useMemo(() => {
    if (!overTimeData || overTimeData.length === 0) return [];
    if (partnerFilter !== "all" && partnersData) {
      const p = partnersData.find(p => p.id === partnerFilter);
      return p ? [p.name] : [];
    }
    const names = new Set<string>();
    overTimeData.forEach(d => {
      Object.keys(d).forEach(k => {
        if (k !== 'date' && k !== 'label' && k !== 'Geral') names.add(k);
      });
    });
    return Array.from(names);
  }, [overTimeData, partnerFilter, partnersData]);

  const processedFunnelData = React.useMemo(() => {
    if (!funnelData || funnelData.length === 0) return [];
    
    return funnelData.map((item, index) => {
       let dropPct = null;
       let prevCount = index > 0 ? funnelData[index - 1].user_count : null;
       
       if (prevCount !== null && prevCount > 0) {
           const drop = prevCount - item.user_count;
           dropPct = Math.round((drop / prevCount) * 100);
       }
       
       return {
          ...item,
          dropStr: (dropPct !== null && dropPct > 0) ? `-${dropPct}%` : ''
       };
    });
  }, [funnelData]);

  // Process buckets data to group by completing bucket regardless of partner for a global view
  const globalBuckets = React.useMemo(() => {
    if (!bucketsData) return [];
    const grouped = bucketsData.reduce((acc, curr) => {
      acc[curr.completion_bucket] = (acc[curr.completion_bucket] || 0) + curr.applications_count;
      return acc;
    }, {} as Record<string, number>);
    
    return Object.keys(grouped).sort().map(bucket => ({
      name: bucket,
      count: grouped[bucket]
    }));
  }, [bucketsData]);

  const exportFunnelUsers = async () => {
    try {
      setIsExporting(true);
      const users = await getAdminFunnelUsers();
      
      const BOM = "\uFEFF";
      const headers = ["Nome Completo", "WhatsApp", "Fase do Funil", "Fase da Candidatura", "Candidatura Ativa", "Progresso", "É Dependente?", "Nome do Responsável"];
      const rows = users.map(u => {
         let progressStr = "—";
         if (u.progress_percent !== null && u.progress_percent !== undefined) {
            progressStr = `${u.progress_percent}% (${u.progress_filled}/${u.progress_total} resps)`;
         }
         return [
           u.full_name || "—",
           u.whatsapp || "—",
           u.funnel_phase || "—",
           u.furthest_passport_phase || "—",
           u.active_partner_name || "—",
           progressStr,
           u.is_dependent ? "Sim" : "Não",
           u.parent_full_name || "—"
         ];
      });
      
      const csvContent = BOM + [
         headers.join(";"),
         ...rows.map(r => r.map(c => `"${String(c).replace(/"/g, '""')}"`).join(";"))
      ].join("\n");
      
      const blob = new Blob([csvContent], { type: "text/csv;charset=utf-8;" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `usuarios_funil_${new Date().toISOString().slice(0, 10)}.csv`;
      link.click();
      URL.revokeObjectURL(url);
      toast.success("Usuários exportados com sucesso!");
    } catch (e) {
      console.error(e);
      toast.error("Erro ao exportar usuários.");
    } finally {
      setIsExporting(false);
    }
  };

  if (isLoadingFunnel || isLoadingPhases || isLoadingFurthest || isLoadingPartnerFunnel || isLoadingBuckets || isLoadingOverTime) {
    return (
      <div className="flex justify-center items-center h-full min-h-[500px]">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  return (
    <div className="p-6 space-y-6">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Dashboard do Passaporte</h1>
        <p className="text-muted-foreground mt-2">
          Visão consolidada do fluxo do passaporte de elegibilidade, do cadastro até a submissão das candidaturas.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Funil Principal */}
        <Card className="col-span-1 lg:col-span-2">
          <CardHeader className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
            <div>
              <CardTitle>Funil de Conversão (Global)</CardTitle>
              <CardDescription>Usuários ativos e candidaturas desde o lançamento do Passaporte (09/03).</CardDescription>
            </div>
            <Button variant="outline" size="sm" onClick={exportFunnelUsers} disabled={isExporting}>
              <Download className="mr-2 h-4 w-4" /> Exportar CSV
            </Button>
          </CardHeader>
          <CardContent className="h-[400px]">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart
                data={processedFunnelData}
                layout="vertical"
                margin={{ top: 20, right: 80, left: 100, bottom: 5 }}
              >
                <CartesianGrid strokeDasharray="3 3" horizontal={false} />
                <XAxis type="number" />
                <YAxis dataKey="step_name" type="category" width={150} />
                <Tooltip cursor={{ fill: 'transparent' }} />
                <Bar dataKey="user_count" fill="#3b82f6" radius={[0, 4, 4, 0]} name="Usuários">
                   <LabelList dataKey="dropStr" content={<CustomDropBadge />} />
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>

        {/* Candidaturas ao Longo do Tempo */}
        <Card className="col-span-1 lg:col-span-2">
          <CardHeader className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
            <div>
              <CardTitle>Candidaturas ao Longo do Tempo</CardTitle>
              <CardDescription>Volume de novas candidaturas criadas diariamente.</CardDescription>
            </div>
            <div className="flex flex-col sm:flex-row gap-2">
              <Select value={partnerFilter} onValueChange={setPartnerFilter}>
                <SelectTrigger className="w-[200px]">
                  <SelectValue placeholder="Parceiro" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">Todos os Parceiros</SelectItem>
                  {partnersData?.map(p => (
                    <SelectItem key={p.id} value={p.id}>{p.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Select 
                value={daysFilter === null ? "all" : daysFilter.toString()} 
                onValueChange={(val) => setDaysFilter(val === "all" ? null : parseInt(val))}
              >
                <SelectTrigger className="w-[150px]">
                  <SelectValue placeholder="Período" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="7">Últimos 7 dias</SelectItem>
                  <SelectItem value="15">Últimos 15 dias</SelectItem>
                  <SelectItem value="30">Últimos 30 dias</SelectItem>
                  <SelectItem value="60">Últimos 60 dias</SelectItem>
                  <SelectItem value="all">Todo o período</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </CardHeader>
          <CardContent className="h-[300px]">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart
                data={overTimeData}
                margin={{ top: 20, right: 30, left: 10, bottom: 5 }}
              >
                <CartesianGrid strokeDasharray="3 3" vertical={false} />
                <XAxis dataKey="label" />
                <YAxis />
                <Tooltip content={<CustomTooltip />} />
                <Legend />
                {currentPartnersInChart.map((name, i) => (
                  <Bar 
                    key={name}
                    dataKey={name} 
                    stackId="a"
                    fill={COLORS[i % COLORS.length]} 
                    name={name} 
                  />
                ))}
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>

        {/* Fase Atual do Passaporte */}
        <Card>
          <CardHeader>
            <CardTitle>Fase Atual do Passaporte</CardTitle>
            <CardDescription>Onde os usuários estão parados neste momento.</CardDescription>
          </CardHeader>
          <CardContent className="h-[300px]">
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie
                  data={phasesData}
                  cx="50%"
                  cy="50%"
                  outerRadius={100}
                  fill="#8884d8"
                  dataKey="total_users"
                  nameKey="passport_phase"
                  label={({ passport_phase, percent }) => `${passport_phase}: ${(percent * 100).toFixed(0)}%`}
                >
                  {phasesData?.map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={COLORS[index % COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip />
              </PieChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>

        {/* Fase Mais Avançada */}
        <Card>
          <CardHeader>
            <CardTitle>Fase Mais Avançada Alcançada</CardTitle>
            <CardDescription>O mais longe que o usuário já chegou (Métrica de Sucesso).</CardDescription>
          </CardHeader>
          <CardContent className="h-[300px]">
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie
                  data={furthestPhasesData}
                  cx="50%"
                  cy="50%"
                  innerRadius={60}
                  outerRadius={100}
                  fill="#82ca9d"
                  dataKey="total_users"
                  nameKey="furthest_passport_phase"
                  label={({ furthest_passport_phase, percent }) => `${furthest_passport_phase}: ${(percent * 100).toFixed(0)}%`}
                >
                  {furthestPhasesData?.map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={COLORS[(index + 2) % COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip />
              </PieChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>

        {/* Desempenho dos Formulários dos Parceiros */}
        <Card className="col-span-1 lg:col-span-2">
          <CardHeader>
            <CardTitle>Progresso de Preenchimento dos Formulários</CardTitle>
            <CardDescription>Candidaturas distribuídas por porcentagem de conclusão.</CardDescription>
          </CardHeader>
          <CardContent className="h-[300px]">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart
                data={globalBuckets}
                margin={{ top: 20, right: 30, left: 20, bottom: 5 }}
              >
                <CartesianGrid strokeDasharray="3 3" vertical={false} />
                <XAxis dataKey="name" />
                <YAxis />
                <Tooltip cursor={{ fill: 'transparent' }} />
                <Bar dataKey="count" fill="#10b981" radius={[4, 4, 0, 0]} name="Candidaturas" />
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>

        {/* Tabela de Conversão de Parceiros */}
        <Card className="col-span-1 lg:col-span-2">
          <CardHeader>
            <CardTitle>Funil por Parceiro Institucional</CardTitle>
            <CardDescription>Conversão de cliques no Explorar até Candidatura Submetida.</CardDescription>
          </CardHeader>
          <CardContent>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Parceiro</TableHead>
                  <TableHead className="text-right">Cliques</TableHead>
                  <TableHead className="text-right">Cliques Externos</TableHead>
                  <TableHead className="text-right">Iniciadas</TableHead>
                  <TableHead className="text-right">Concluídas</TableHead>
                  <TableHead className="text-right">Tx Conversão (Iniciada ➔ Concluída)</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {partnerFunnelData?.map((row) => (
                  <TableRow key={row.partner_id}>
                    <TableCell className="font-medium">{row.partner_name || 'Desconhecido'}</TableCell>
                    <TableCell className="text-right">{row.total_unique_clicks}</TableCell>
                    <TableCell className="text-right">{row.total_external_redirect_clicks}</TableCell>
                    <TableCell className="text-right">{row.total_applications_started}</TableCell>
                    <TableCell className="text-right">{row.total_applications_submitted}</TableCell>
                    <TableCell className="text-right">
                      {row.total_applications_started > 0 
                        ? `${((row.total_applications_submitted / row.total_applications_started) * 100).toFixed(1)}%` 
                        : '0%'}
                    </TableCell>
                  </TableRow>
                ))}
                {(!partnerFunnelData || partnerFunnelData.length === 0) && (
                  <TableRow>
                    <TableCell colSpan={5} className="text-center py-4 text-muted-foreground">
                      Nenhum dado encontrado.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
