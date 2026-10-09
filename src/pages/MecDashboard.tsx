import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { getMecDashboard, cohortRate } from "@/services/mecDashboardService";

const dateLabel = (date: string | null) => date ? new Date(date).toLocaleString("pt-BR") : "Sem observação";
const rateLabel = (n: number, d: number) => {
  const rate = cohortRate(n, d);
  return rate === null ? "Sem denominador elegível" : rate.toFixed(1) + "%";
};

export default function MecDashboard() {
  const [days, setDays] = useState<number | null>(30);
  const [entity, setEntity] = useState("all");
  const overview = useQuery({
    queryKey: ["mecEngagementEntities", days], queryFn: () => getMecDashboard(undefined, days),
  });
  const query = useQuery({
    queryKey: ["mecEngagementDashboard", entity, days],
    queryFn: () => getMecDashboard(entity === "all" ? undefined : entity, days),
  });
  const data = query.data;
  return <div className="p-6 space-y-6">
    <div><h1 className="text-3xl font-bold tracking-tight">Dashboard Educacional MEC</h1>
      <p className="text-muted-foreground mt-2">Engajamento em oportunidades MEC. O redirect é a saída para o destino externo; não confirma candidatura concluída.</p>
    </div>
    <div className="flex flex-wrap gap-2">
      <Select value={days === null ? "all" : String(days)} onValueChange={v => { setDays(v === "all" ? null : Number(v)); setEntity("all"); }}>
        <SelectTrigger className="w-[200px]" aria-label="Período"><SelectValue /></SelectTrigger>
        <SelectContent>{[7, 15, 30, 60].map(d => <SelectItem key={d} value={String(d)}>Últimos {d} dias</SelectItem>)}<SelectItem value="all">Todo o período</SelectItem></SelectContent>
      </Select>
      <Select value={entity} onValueChange={setEntity}>
        <SelectTrigger className="w-[360px]" aria-label="Oportunidade MEC"><SelectValue /></SelectTrigger>
        <SelectContent><SelectItem value="all">Todas as oportunidades MEC</SelectItem>
          {overview.data?.entities.map(e => <SelectItem key={e.entity_id} value={e.entity_id}>{e.entity_id}</SelectItem>)}
        </SelectContent>
      </Select>
    </div>
    {query.isLoading && <div className="flex items-center gap-2" role="status"><Loader2 className="h-6 w-6 animate-spin text-primary" />Carregando métricas MEC…</div>}
    {(query.isError || overview.isError) && <Card><CardContent className="pt-6" role="alert">
      <p>Não foi possível carregar as métricas MEC. Verifique seu acesso e tente novamente.</p>
      <Button variant="outline" onClick={() => { void query.refetch(); void overview.refetch(); }}>Tentar novamente</Button>
    </CardContent></Card>}
    {!query.isError && !overview.isError && data && <>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        {([["Visualizações de card", data.totals.card_view], ["Cliques no card", data.totals.card_click], ["Candidatar — redirects", data.totals.redirect]] as const).map(([title, value]) =>
          <Card key={title}><CardHeader><CardTitle>{title}</CardTitle><CardDescription>Volume bruto de eventos no período</CardDescription></CardHeader>
            <CardContent className="text-3xl font-bold">{value.toLocaleString("pt-BR")}</CardContent></Card>)}
      </div>
      <Card><CardHeader><CardTitle>Cobertura e pessoas</CardTitle></CardHeader><CardContent className="space-y-2">
        <p>{data.totals.distinct_users} usuários autenticados distintos · {data.totals.distinct_identities} identidades observadas (usuário ou sessão anônima).</p>
        <p>Primeiro evento MEC observado: {dateLabel(data.coverage.first_observed_at)}. Primeira visualização observada: {dateLabel(data.coverage.first_view_at)}.</p>
        <p>Janela: {data.period.from ? dateLabel(data.period.from) : "Todo o histórico"} até {dateLabel(data.period.to)}.</p>
        <p className="text-muted-foreground">Volumes incluem {data.coverage.legacy_events} eventos históricos agregados no recorte. A cobertura observada pode ser parcial. Acesso direto ao detalhe e histórico sem visualizações podem produzir volumes não monotônicos.</p>
      </CardContent></Card>
      <Card><CardHeader><CardTitle>Funil MEC — coorte sequencial</CardTitle>
        <CardDescription>Unidade: par identidade + oportunidade. Eventos individuais observados no mesmo período, com ordem estrita visualização → clique → redirect. Agregados legados ficam fora desta coorte.</CardDescription>
      </CardHeader><CardContent>
        <Table><TableHeader><TableRow><TableHead>Etapa</TableHead><TableHead>Pares elegíveis</TableHead><TableHead>Taxa sobre etapa anterior</TableHead></TableRow></TableHeader><TableBody>
          <TableRow><TableCell>Viu card</TableCell><TableCell>{data.cohort.viewers}</TableCell><TableCell>—</TableCell></TableRow>
          <TableRow><TableCell>Clicou card após visualizar</TableCell><TableCell>{data.cohort.clickers}</TableCell><TableCell>{rateLabel(data.cohort.clickers, data.cohort.viewers)}</TableCell></TableRow>
          <TableRow><TableCell>Redirect após clicar (terminal)</TableCell><TableCell>{data.cohort.redirectors}</TableCell><TableCell>{rateLabel(data.cohort.redirectors, data.cohort.clickers)}</TableCell></TableRow>
        </TableBody></Table>
      </CardContent></Card>
      <Card><CardHeader><CardTitle>Volumes por oportunidade MEC</CardTitle><CardDescription>Usuários e eventos não são aditivos entre oportunidades.</CardDescription></CardHeader><CardContent>
        <Table><TableHeader><TableRow><TableHead>Oportunidade (ID)</TableHead><TableHead>Views</TableHead><TableHead>Cliques</TableHead><TableHead>Redirects</TableHead><TableHead>Usuários distintos</TableHead></TableRow></TableHeader><TableBody>
          {data.entities.map(e => <TableRow key={e.entity_id}><TableCell className="break-all">{e.entity_id}</TableCell><TableCell>{e.card_view}</TableCell><TableCell>{e.card_click}</TableCell><TableCell>{e.redirect}</TableCell><TableCell>{e.distinct_users}</TableCell></TableRow>)}
          {!data.entities.length && <TableRow><TableCell colSpan={5} className="text-center py-4 text-muted-foreground">Nenhum evento MEC encontrado no período.</TableCell></TableRow>}
        </TableBody></Table>
      </CardContent></Card>
    </>}
  </div>;
}

