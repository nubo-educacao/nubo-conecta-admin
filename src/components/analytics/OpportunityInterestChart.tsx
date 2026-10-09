import { useQuery } from '@tanstack/react-query';
import { Skeleton } from '@/components/ui/skeleton';
import { fetchOpportunityInterest } from '@/services/opportunityInterestService';
import type { DateRange } from '@/lib/analytics-queries';
export function OpportunityInterestChart({ dateRange }: { dateRange?: DateRange }) {
  const { data = [], isLoading, error } = useQuery({
    queryKey: ['opportunity-interest', dateRange],
    queryFn: () => fetchOpportunityInterest(dateRange),
    staleTime: 1000 * 60 * 5,
    throwOnError: false,
  });
  return (
    <div className="chart-container">
      <h3 className="text-lg font-semibold font-display">Oportunidades de maior interesse</h3>
      <p className="text-sm text-muted-foreground mb-6">Cliques em cards de oportunidades no período selecionado.</p>
      {isLoading ? <Skeleton className="h-[250px] w-full" /> : error ? (
        <p role="alert" className="text-sm text-muted-foreground">Não foi possível carregar o interesse por oportunidades.</p>
      ) : data.length === 0 ? (
        <p className="text-sm text-muted-foreground">Nenhum clique em oportunidades neste período.</p>
      ) : (
        <ol className="space-y-4">
          {data.map((item) => (
            <li key={item.opportunity_id} className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="font-medium text-sm break-words">{item.title}</p>
                <p className="text-xs text-muted-foreground">{item.provider}</p>
              </div>
              <span className="text-sm font-semibold whitespace-nowrap">{Number(item.clicks).toLocaleString('pt-BR')} cliques</span>
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}

