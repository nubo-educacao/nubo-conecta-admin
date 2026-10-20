import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { FunnelChart } from "@/components/analytics/FunnelChart";
import { MecVolumesTable, mecOpportunityLabel, useMecVolumes } from "@/components/mec/MecVolumesTable";
import { isRedirectUnmeasured, mecCohortSteps, redirectCoverageText } from "@/components/mec/mecCoverage";
import { getMecDashboard, cohortRate, mecRangeFromDashboard } from "@/services/mecDashboardService";

const dateLabel = (date: string | null) => date ? new Date(date).toLocaleString("pt-BR") : "Sem observação";
const rateLabel = (n: number, d: number) => {
  const rate = cohortRate(n, d);
  return rate === null ? "Sem denominador elegível" : rate.toFixed(1) + "%";
};
const PERIODS = [7, 30, 90];

export default function MecDashboard() {
  const [days, setDays] = useState<number | null>(30);
  const [entity, setEntity] = useState("all");
  const [entityLabel, setEntityLabel] = useState<string | null>(null);
  // "all" shares its key with the selected-entity query, so one request serves both.
  const overview = useQuery({
    queryKey: ["mecEngagementDashboard", "all", days], queryFn: () => getMecDashboard(undefined, days),
  });
  const query = useQuery({
    queryKey: ["mecEngagementDashboard", entity, days],
    queryFn: () => getMecDashboard(entity === "all" ? undefined : entity, days),
  });
  // Volumes, selector and institutions reuse the window the server normalized for the cohort.
  const range = useMemo(() => overview.data ? mecRangeFromDashboard(overview.data) : null, [overview.data]);
  const volumes = useMecVolumes(range);
  const data = query.data;
  const redirectMeasured = overview.data
    ? !isRedirectUnmeasured(overview.data.coverage.redirect, overview.data.totals.redirect)
    : true;

  const options = volumes.query.data?.rows ?? [];
  const selectedMissing = entity !== "all" && !options.some(o => o.entity_id === entity);

  return <div className="p-6 space-y-6">
    <div><h1 className="text-3xl font-bold tracking-tight">Dashboard Educacional MEC</h1>
      <p className="text-muted-foreground mt-2">Engajamento em oportunidades MEC. O redirect é a saída para o destino externo; não confirma candidatura concluída.</p>
    </div>
    <div className="flex flex-wrap gap-2">
      <Select value={days === null ? "all" : String(days)} onValueChange={v => {
        setDays(v === "all" ? null : Number(v)); setEntity("all"); setEntityLabel(null); volumes.setPage(1);
      }}>
        <SelectTrigger className="w-[200px]" aria-label="Período"><SelectValue /></SelectTrigger>
        <SelectContent>{PERIODS.map(d => <SelectItem key={d} value={String(d)}>Últimos {d} dias</SelectItem>)}<SelectItem value="all">Todo o período</SelectItem></SelectContent>
      </Select>
      {/* Value is entity_id (UUID without mec_), the key the preserved dashboard RPC expects. */}
      <Select value={entity} onValueChange={v => {
        setEntity(v);
        const row = options.find(o => o.entity_id === v);
        setEntityLabel(row ? mecOpportunityLabel(row) : null);
      }}>
        <SelectTrigger className="w-[360px]" aria-label="Oportunidade MEC"><SelectValue /></SelectTrigger>
        <SelectContent><SelectItem value="all">Todas as oportunidades MEC</SelectItem>
          {selectedMissing && <SelectItem value={entity}>{entityLabel ?? "Oportunidade selecionada"}</SelectItem>}
          {options.map(o => <SelectItem key={o.entity_id} value={o.entity_id}>{mecOpportunityLabel(o)}</SelectItem>)}
        </SelectContent>
      </Select>
    </div>
    <p className="text-xs text-muted-foreground">O seletor lista as oportunidades da página atual de volumes; use a busca e os filtros da tabela para encontrar outras.</p>
    {query.isLoading && <div className="flex items-center gap-2" role="status"><Loader2 className="h-6 w-6 animate-spin text-primary" />Carregando métricas MEC…</div>}
    {(query.isError || overview.isError) && <Card><CardContent className="pt-6" role="alert">
      <p>Não foi possível carregar as métricas MEC. Verifique seu acesso e tente novamente.</p>
      <Button variant="outline" onClick={() => { void query.refetch(); void overview.refetch(); }}>Tentar novamente</Button>
    </CardContent></Card>}
    {!query.isError && !overview.isError && data && <>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        {([["Visualizações de card", data.totals.card_view, "card_view"], ["Cliques no card", data.totals.card_click, "card_click"], ["Candidatar — redirects", data.totals.redirect, "redirect"]] as const).map(([title, value, key]) =>
          <Card key={title}><CardHeader><CardTitle>{title}</CardTitle><CardDescription>Volume bruto de eventos no período</CardDescription></CardHeader>
            <CardContent className="text-3xl font-bold" data-testid={`mec-total-${key}`}>
              {key === "redirect" && isRedirectUnmeasured(data.coverage.redirect, value) ? "Não instrumentado" : value.toLocaleString("pt-BR")}
            </CardContent></Card>)}
      </div>
      <Card><CardHeader><CardTitle>Cobertura e pessoas</CardTitle></CardHeader><CardContent className="space-y-2">
        <p>{data.totals.distinct_users} usuários autenticados distintos · {data.totals.distinct_identities} identidades observadas (usuário ou sessão anônima).</p>
        <p>Primeiro evento MEC observado: {dateLabel(data.coverage.first_observed_at)}. Primeira visualização observada: {dateLabel(data.coverage.first_view_at)}.</p>
        <p>{redirectCoverageText(data.coverage.redirect)}</p>
        <p>Janela: {data.period.from ? dateLabel(data.period.from) : "Todo o histórico"} até {dateLabel(data.period.to)}.</p>
        <p className="text-muted-foreground">Volumes incluem {data.coverage.legacy_events} eventos históricos agregados no recorte. A cobertura observada pode ser parcial. Acesso direto ao detalhe e histórico sem visualizações podem produzir volumes não monotônicos.</p>
      </CardContent></Card>
      <Card><CardHeader><CardTitle>Funil MEC — coorte sequencial</CardTitle>
        <CardDescription>Unidade: par identidade + oportunidade. Eventos individuais observados no mesmo período, com ordem estrita visualização → clique → redirect. Agregados legados ficam fora desta coorte; os totais de eventos acima não são taxas da coorte.</CardDescription>
      </CardHeader><CardContent className="space-y-6">
        <FunnelChart steps={mecCohortSteps(data)} mode="sequential_cohort" unitLabel="pares identidade + oportunidade" />
        <Table aria-label="Detalhe da coorte MEC"><TableHeader><TableRow><TableHead>Etapa</TableHead><TableHead>Pares elegíveis</TableHead><TableHead>Taxa sobre etapa anterior</TableHead></TableRow></TableHeader><TableBody>
          <TableRow><TableCell>Viu card</TableCell><TableCell>{data.cohort.viewers}</TableCell><TableCell>—</TableCell></TableRow>
          <TableRow><TableCell>Clicou card após visualizar</TableCell><TableCell>{data.cohort.clickers}</TableCell><TableCell>{rateLabel(data.cohort.clickers, data.cohort.viewers)}</TableCell></TableRow>
          <TableRow><TableCell>Redirect após clicar (terminal)</TableCell>
            {isRedirectUnmeasured(data.coverage.redirect, data.cohort.redirectors)
              ? <><TableCell>Não instrumentado</TableCell><TableCell>—</TableCell></>
              : <><TableCell>{data.cohort.redirectors}</TableCell><TableCell>
                {["unknown", "partial", "observed"].includes(data.coverage.redirect?.status ?? "")
                  ? "Indisponível (cobertura incompleta)"
                  : rateLabel(data.cohort.redirectors, data.cohort.clickers)}
              </TableCell></>}
          </TableRow>
        </TableBody></Table>
      </CardContent></Card>
    </>}
    {!overview.isError && overview.data && <MecVolumesTable volumes={volumes} redirectMeasured={redirectMeasured} />}
  </div>;
}
