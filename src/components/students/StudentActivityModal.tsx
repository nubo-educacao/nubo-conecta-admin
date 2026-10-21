import { useState, type ReactNode } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Loader2 } from 'lucide-react';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Button } from '@/components/ui/button';
import type { AttributionFilter } from '@/lib/attributionFilter';
import {
  ACTIVITY_PAGE_SIZE, getActivityMatches, getActivityClicks, getActivityApplications,
  type ActivityPage, type StudentClick, type ActivityApplication,
} from '@/services/studentActivityService';
import type { UserMatch } from '@/services/studentsService';

type ActivityTab = 'matches' | 'clicks' | 'applications';
const labels: Record<ActivityTab, string> = { matches: 'Matches', clicks: 'Clicks', applications: 'Candidaturas' };
const empty: Record<ActivityTab, string> = {
  matches: 'Nenhum match encontrado.', clicks: 'Nenhum click encontrado.', applications: 'Nenhuma candidatura encontrada.',
};
interface Props {
  isOpen: boolean;
  onOpenChange: (open: boolean) => void;
  studentId: string | null;
  studentName?: string | null;
  attribution?: AttributionFilter;
}
export function StudentActivityModal({ isOpen, onOpenChange, studentId, studentName, attribution = {} }: Props) {
  return <Dialog open={isOpen} onOpenChange={onOpenChange}>
    <DialogContent className="flex max-h-[88vh] w-[calc(100%-2rem)] max-w-4xl flex-col overflow-hidden p-6 sm:p-8">
      <DialogHeader>
        <DialogTitle>Atividade do Estudante</DialogTitle>
        <DialogDescription>{studentName || 'Estudante selecionado'} — matches, clicks e candidaturas.</DialogDescription>
      </DialogHeader>
      {isOpen && studentId && <ActivityTabs key={studentId} studentId={studentId} attribution={attribution} />}
    </DialogContent>
  </Dialog>;
}

function ActivityTabs({ studentId, attribution }: { studentId: string; attribution: AttributionFilter }) {
  const [tab, setTab] = useState<ActivityTab>('matches');
  const [pages, setPages] = useState<Record<ActivityTab, number>>({ matches: 0, clicks: 0, applications: 0 });
  const setPage = (page: number) => setPages(previous => ({ ...previous, [tab]: page }));
  const common = { studentId, attribution, page: pages[tab], setPage };
  return <Tabs value={tab} onValueChange={value => setTab(value as ActivityTab)} className="flex min-h-0 flex-1 flex-col">
    <TabsList className="grid w-full shrink-0 grid-cols-3">
      <TabsTrigger value="matches">Matches</TabsTrigger>
      <TabsTrigger value="clicks">Clicks</TabsTrigger>
      <TabsTrigger value="applications">Candidaturas</TabsTrigger>
    </TabsList>
    <TabsContent value={tab} className="min-h-0 overflow-y-auto">
      {tab === 'matches' && <ActivityCollection {...common} tab="matches" load={getActivityMatches}
        renderRow={match => <MatchRow match={match} />} rowKey={match => match.unified_opportunity_id} />}
      {tab === 'clicks' && <ActivityCollection {...common} tab="clicks" load={getActivityClicks}
        renderRow={click => <ClickRow click={click} />} rowKey={click => click.id} />}
      {tab === 'applications' && <ActivityCollection {...common} tab="applications" load={getActivityApplications}
        renderRow={application => <ApplicationRow application={application} />} rowKey={application => application.id} />}
    </TabsContent>
  </Tabs>;
}

function ActivityCollection<T>({ studentId, tab, page, setPage, attribution, load, renderRow, rowKey }: {
  studentId: string; tab: ActivityTab; page: number; setPage: (page: number) => void;
  attribution: AttributionFilter;
  load: (studentId: string, page: number, attribution: AttributionFilter) => Promise<ActivityPage<T>>;
  renderRow: (row: T) => ReactNode; rowKey: (row: T) => string;
}) {
  const { data, isPending, isError, isFetching, refetch } = useQuery({
    queryKey: ['student-activity', studentId, tab, page, ACTIVITY_PAGE_SIZE, attribution],
    queryFn: () => load(studentId, page, attribution),
    retry: false, retryOnMount: false, staleTime: 30_000,
    // No previous-student/page placeholder: late responses stay in their own cache entry.
  });
  return <section aria-label={labels[tab]} className="space-y-4 py-4">
    {isPending ? <div role="status" className="flex items-center gap-2 py-8">
      <Loader2 aria-hidden="true" className="h-5 w-5 animate-spin" /> Carregando {labels[tab]}…
    </div> : isError ? <div role="alert" className="space-y-3 rounded-xl border p-4">
      <p>Não foi possível carregar {labels[tab]}. Tente novamente.</p>
      <Button variant="outline" disabled={isFetching} onClick={() => refetch()}>Tentar novamente</Button>
    </div> : data && <>
      <p className="text-sm text-muted-foreground">Total: {data.count}</p>
      {data.data.length === 0 ? <p className="rounded-xl border p-5 text-sm text-muted-foreground">
        {page === 0 ? empty[tab] : 'Nenhum registro nesta página.'}
      </p> : <ul className="space-y-3">{data.data.map(row =>
        <li key={rowKey(row)} className="space-y-2 rounded-xl border p-4">{renderRow(row)}</li>)}</ul>}
    </>}
    <nav aria-label={'Paginação de ' + labels[tab]} className="flex flex-wrap items-center justify-end gap-3">
      <Button variant="outline" size="sm" disabled={page === 0} onClick={() => setPage(page - 1)}>Anterior</Button>
      <span className="text-sm">Página {page + 1}{data && !isError ? ' de ' + Math.max(1, Math.ceil(data.count / ACTIVITY_PAGE_SIZE)) : ''}</span>
      <Button variant="outline" size="sm" disabled={isPending || isError || isFetching || !data || (page + 1) * ACTIVITY_PAGE_SIZE >= data.count}
        onClick={() => setPage(page + 1)}>Próxima</Button>
    </nav>
  </section>;
}
function MatchRow({ match }: { match: UserMatch }) {
  return <>
    <div className="flex items-start justify-between gap-4">
      <div><h3 className="font-semibold">{match.title}</h3><p className="text-sm text-muted-foreground">{match.provider_name}</p></div>
      <span className="font-semibold text-primary">{Math.round(match.match_score)}%</span>
    </div>
    {match.match_details != null && <details className="text-sm"><summary className="cursor-pointer">Detalhes do match</summary>
      <div className="mt-2 rounded-md bg-muted p-3"><MatchDetails value={match.match_details} /></div>
    </details>}
  </>;
}
function MatchDetails({ value }: { value: unknown }): ReactNode {
  if (value == null) return <span>—</span>;
  if (Array.isArray(value)) return <ul className="space-y-1">{value.map((item, index) =>
    <li key={index}><MatchDetails value={item} /></li>)}</ul>;
  if (typeof value === 'object') return <dl className="space-y-2">{Object.entries(value).map(([key, item]) =>
    <div key={key}><dt className="font-medium capitalize">{key.replace(/_/g, ' ')}</dt>
      <dd className="break-words text-muted-foreground"><MatchDetails value={item} /></dd></div>)}</dl>;
  if (typeof value === 'boolean') return value ? 'Sim' : 'Não';
  return String(value);
}

function dateLabel(value: string) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? 'Data indisponível' : date.toLocaleString('pt-BR');
}
function ClickRow({ click }: { click: StudentClick }) {
  return <>
    <h3 className="font-semibold">{click.entity_name || 'Oportunidade'}</h3>
    <p className="text-sm">{click.event_type} · {dateLabel(click.occurred_at)}</p>
    <p className="text-sm text-muted-foreground">Ocorrências: {click.event_count}{click.source ? ' · ' + click.source : ''}</p>
    {click.destination_url && <p className="break-all text-sm text-muted-foreground">{click.destination_url}</p>}
  </>;
}
function ApplicationRow({ application }: { application: ActivityApplication }) {
  const status = { DRAFT: 'Rascunho', SUBMITTED: 'Enviada', redirected: 'Redirecionada' }[application.status] ?? application.status;
  return <>
    <h3 className="font-semibold">{application.partner_name || 'Oportunidade'}</h3>
    {application.institution_name && <p className="text-sm text-muted-foreground">{application.institution_name}</p>}
    <p className="text-sm">{status}</p><p className="text-sm text-muted-foreground">{dateLabel(application.created_at)}</p>
  </>;
}
