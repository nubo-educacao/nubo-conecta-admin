import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { FunnelChart, type FunnelChartStep } from "@/components/analytics/FunnelChart";
import { getPartnerFunnel, type PartnerFunnelData } from "@/services/passportDashboardService";
import {
  FUNNEL_PERIOD_OPTIONS,
  formatBrt,
  funnelPeriodLabel,
  resolveFunnelPeriod,
  type FunnelPeriod,
  type FunnelPeriodPreset,
} from "@/components/b2b/funnelPeriod";

interface PartnerFunnelCardProps {
  institutions?: { id: string; name: string }[];
}

const sum = (rows: PartnerFunnelData[], pick: (r: PartnerFunnelData) => number) =>
  rows.reduce((total, r) => total + Number(pick(r) || 0), 0);

/**
 * "Funil por Parceiro Institucional" (NUB-RD-90a/b): its own period, separate from the
 * time series, over get_tp2_partner_funnel_v2. Each step counts distinct users of that
 * stage on its own; the steps are observed volumes, not a causal cohort.
 */
export function PartnerFunnelCard({ institutions }: PartnerFunnelCardProps) {
  const [institution, setInstitution] = useState("all");
  const [period, setPeriod] = useState<FunnelPeriod>({ preset: "all" });
  // Relative presets are resolved once per selection so the query key stays stable.
  const range = useMemo(() => resolveFunnelPeriod(period), [period]);

  const { data: rows, isLoading, isError } = useQuery({
    queryKey: ["partnerFunnel", "admin", institution, period.preset, period.customFrom ?? null, period.customTo ?? null],
    queryFn: () => getPartnerFunnel(institution, range ?? {}),
    enabled: range !== null,
  });

  const allInstitutions = institution === "all";
  const steps: FunnelChartStep[] = useMemo(() => {
    const list = rows ?? [];
    return [
      { key: "card_click", label: "Clicou no card", value: sum(list, (r) => r.total_unique_clicks) },
      { key: "applications_started", label: "Candidatura iniciada", value: sum(list, (r) => r.total_applications_started) },
      { key: "applications_completed", label: "Candidatura concluída", value: sum(list, (r) => r.total_applications_completed) },
    ];
  }, [rows]);

  return (
    <Card className="col-span-1 lg:col-span-2">
      <CardHeader className="space-y-3">
        <div>
          <CardTitle>Funil por Parceiro Institucional</CardTitle>
          <CardDescription>
            Usuários distintos em cada etapa, contados de forma independente: são volumes observados, não uma coorte que
            percorre as etapas. Conclusão reflete candidaturas submetidas ou redirecionadas. Visualizações do card de
            parceiro não fazem parte desta métrica.
          </CardDescription>
        </div>
        <div className="flex flex-col sm:flex-row flex-wrap gap-2">
          <Select value={institution} onValueChange={setInstitution}>
            <SelectTrigger className="w-[250px]" aria-label="Instituição do funil"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todas as instituições parceiras</SelectItem>
              {institutions?.map((i) => <SelectItem key={i.id} value={i.id}>{i.name}</SelectItem>)}
            </SelectContent>
          </Select>
          <Select value={period.preset} onValueChange={(v) => setPeriod((p) => ({ ...p, preset: v as FunnelPeriodPreset }))}>
            <SelectTrigger className="w-[200px]" aria-label="Período do funil"><SelectValue /></SelectTrigger>
            <SelectContent>
              {FUNNEL_PERIOD_OPTIONS.map((o) => <SelectItem key={o.value} value={o.value}>{o.label}</SelectItem>)}
            </SelectContent>
          </Select>
          {period.preset === "custom" && (
            <>
              <Input type="date" className="w-[170px]" aria-label="Início do período do funil" value={period.customFrom ?? ""}
                onChange={(e) => setPeriod((p) => ({ ...p, customFrom: e.target.value || undefined }))} />
              <Input type="date" className="w-[170px]" aria-label="Fim do período do funil" value={period.customTo ?? ""}
                onChange={(e) => setPeriod((p) => ({ ...p, customTo: e.target.value || undefined }))} />
            </>
          )}
        </div>
        <p className="text-sm font-medium">
          {range === null ? "Período inválido: o início precisa ser anterior ao fim." : `Período: ${funnelPeriodLabel(range)}`}
        </p>
      </CardHeader>
      <CardContent className="space-y-6">
        {isLoading && range !== null && (
          <div className="flex items-center gap-2" role="status"><Loader2 className="h-5 w-5 animate-spin text-primary" />Carregando funil…</div>
        )}
        {isError && (
          <p role="alert" className="text-sm text-destructive">Não foi possível carregar o funil. Verifique seu acesso e tente novamente.</p>
        )}
        {!isError && rows && (
          <>
            <div className="space-y-2">
              <FunnelChart
                steps={steps}
                mode="observed_volumes"
                unitLabel={allInstitutions ? "soma de usuários distintos por instituição" : "usuários distintos"}
                emptyLabel="Nenhum dado encontrado."
              />
              {allInstitutions && (
                <p className="text-xs text-muted-foreground">
                  Em “todas”, cada etapa é a soma das contagens por instituição: quem interagiu com duas instituições conta
                  duas vezes, portanto os valores não são pessoas únicas globais.
                </p>
              )}
              <ul className="flex flex-wrap gap-x-6 gap-y-1 text-sm text-muted-foreground">
                <li>Cliques no card (eventos): {sum(rows, (r) => r.total_card_clicks).toLocaleString("pt-BR")}</li>
                <li>Redirects legados v0 (eventos): {sum(rows, (r) => r.legacy_external_redirects).toLocaleString("pt-BR")}</li>
              </ul>
            </div>
            <Table aria-label="Detalhe do funil por parceiro">
              <TableHeader>
                <TableRow>
                  <TableHead>Parceiro</TableHead>
                  <TableHead className="text-right">Cliques (eventos)</TableHead>
                  <TableHead className="text-right">Usuários que clicaram</TableHead>
                  <TableHead className="text-right">Iniciadas</TableHead>
                  <TableHead className="text-right">Concluídas</TableHead>
                  <TableHead className="text-right">Tx Conversão (Iniciada ➔ Concluída)</TableHead>
                  <TableHead className="text-right">Redirects legados v0</TableHead>
                  <TableHead className="text-right">Última atividade</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.partner_id}>
                    <TableCell className="font-medium">{row.partner_name || "Desconhecido"}</TableCell>
                    <TableCell className="text-right">{row.total_card_clicks}</TableCell>
                    <TableCell className="text-right">{row.total_unique_clicks}</TableCell>
                    <TableCell className="text-right">{row.total_applications_started}</TableCell>
                    <TableCell className="text-right">{row.total_applications_completed}</TableCell>
                    <TableCell className="text-right">
                      {row.total_applications_started > 0
                        ? `${((row.total_applications_completed / row.total_applications_started) * 100).toFixed(1)}%`
                        : "—"}
                    </TableCell>
                    <TableCell className="text-right">{row.legacy_external_redirects}</TableCell>
                    <TableCell className="text-right">{row.last_activity_at ? formatBrt(row.last_activity_at) : "sem atividade"}</TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={8} className="text-center py-4 text-muted-foreground">Nenhum dado encontrado.</TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
            <p className="text-xs text-muted-foreground">
              Redirects legados v0: redirect externo da v0, não somado a concluídas. Última atividade considera todo o
              histórico, independentemente do período selecionado (horário de Brasília).
            </p>
          </>
        )}
      </CardContent>
    </Card>
  );
}
