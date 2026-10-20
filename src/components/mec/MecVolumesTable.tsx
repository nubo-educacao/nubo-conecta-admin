import { useCallback, useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { getMecOpportunityVolumes, getMecVolumeInstitutions } from "@/services/mecDashboardService";
import type { AnalyticsRange, MecVolumeRow, MecVolumes } from "@/types/productAnalytics";

export const MEC_VOLUMES_PAGE_SIZE = 25;
type VolumeOrder = MecVolumes["order"];
const ORDERS: VolumeOrder[] = ["views", "clicks", "redirects", "users"];
const PARAM = { search: "busca", institution: "instituicao", type: "modalidade", order: "ordem", page: "pagina" } as const;
type FilterKey = Exclude<keyof typeof PARAM, "page">;

const MODALITY_LABEL: Record<string, string> = { sisu: "SiSU", prouni: "ProUni" };
export const modalityLabel = (type: string | null) => (type ? MODALITY_LABEL[type] ?? type : "—");

/** Course + institution, never the UUID (NUB-RD-91a/d). */
export function mecOpportunityLabel(row: Pick<MecVolumeRow, "course_title" | "institution_name" | "in_catalog">): string {
  if (!row.in_catalog || !row.course_title) return "Oportunidade fora do catálogo atual";
  return row.institution_name ? `${row.course_title} — ${row.institution_name}` : row.course_title;
}

const rangeKey = (range: AnalyticsRange | null) => [range?.from?.toISOString() ?? null, range?.to?.toISOString() ?? null];

/**
 * Server-paginated MEC volumes with search/filter/sort/page state in the URL.
 * `range` must be the server-normalized window of the MEC dashboard (mecRangeFromDashboard),
 * so cohort and volumes never use two different "now"s; null keeps the query idle.
 */
export function useMecVolumes(range: AnalyticsRange | null) {
  const [params, setParams] = useSearchParams();
  const search = params.get(PARAM.search) ?? "";
  const institutionId = params.get(PARAM.institution) ?? "";
  const type = params.get(PARAM.type) ?? "";
  const orderParam = params.get(PARAM.order) as VolumeOrder | null;
  const order: VolumeOrder = orderParam && ORDERS.includes(orderParam) ? orderParam : "views";
  const page = Math.max(1, parseInt(params.get(PARAM.page) ?? "1", 10) || 1);
  const offset = (page - 1) * MEC_VOLUMES_PAGE_SIZE;

  const update = useCallback((mutate: (next: URLSearchParams) => void) => {
    setParams((prev) => {
      const next = new URLSearchParams(prev);
      mutate(next);
      return next;
    }, { replace: true });
  }, [setParams]);

  /** Any filter change goes back to the first page. */
  const setFilter = useCallback((key: FilterKey, value: string) => update((next) => {
    if (value && value !== "all") next.set(PARAM[key], value);
    else next.delete(PARAM[key]);
    next.delete(PARAM.page);
  }), [update]);

  const setPage = useCallback((value: number) => update((next) => {
    if (value > 1) next.set(PARAM.page, String(value));
    else next.delete(PARAM.page);
  }), [update]);

  const query = useQuery({
    queryKey: ["mecOpportunityVolumes", ...rangeKey(range), search, institutionId, type, order, offset],
    queryFn: () => getMecOpportunityVolumes({
      range: range ?? undefined,
      search: search || undefined,
      institutionId: institutionId || undefined,
      type: type || undefined,
      order,
      limit: MEC_VOLUMES_PAGE_SIZE,
      offset,
    }),
    enabled: range !== null,
    // Keep the previous page on screen while the next key loads; a late response for an
    // old key never replaces the current one because each key caches separately.
    placeholderData: keepPreviousData,
  });

  const institutions = useQuery({
    queryKey: ["mecVolumeInstitutions", ...rangeKey(range)],
    queryFn: () => getMecVolumeInstitutions(range ?? undefined),
    enabled: range !== null,
  });

  return { search, institutionId, type, order, page, offset, setFilter, setPage, query, institutions };
}

type MecVolumesState = ReturnType<typeof useMecVolumes>;

const SORTABLE: { order: VolumeOrder; label: string; sortLabel: string; pick: (r: MecVolumeRow) => number }[] = [
  { order: "views", label: "Views", sortLabel: "views", pick: (r) => r.card_view },
  { order: "clicks", label: "Cliques", sortLabel: "cliques", pick: (r) => r.card_click },
  { order: "redirects", label: "Redirects", sortLabel: "redirects", pick: (r) => r.redirect },
  { order: "users", label: "Pessoas distintas", sortLabel: "pessoas distintas", pick: (r) => r.distinct_identities },
];

interface MecVolumesTableProps {
  volumes: MecVolumesState;
  /** False when the redirect has no measurement in the window: cells show n/i, not 0. */
  redirectMeasured: boolean;
}

export function MecVolumesTable({ volumes, redirectMeasured }: MecVolumesTableProps) {
  const { search, institutionId, type, order, page, setFilter, setPage, query, institutions } = volumes;
  const [searchInput, setSearchInput] = useState(search);

  // Debounce typing 300 ms before it reaches the URL (and the server).
  useEffect(() => {
    if (searchInput.trim() === search) return;
    const timer = setTimeout(() => setFilter("search", searchInput.trim()), 300);
    return () => clearTimeout(timer);
  }, [searchInput, search, setFilter]);

  const data = query.data;
  const rows = data?.rows ?? [];

  return (
    <Card>
      <CardHeader className="space-y-3">
        <div>
          <CardTitle>Volumes por oportunidade MEC</CardTitle>
          <CardDescription>Usuários e eventos não são aditivos entre oportunidades.</CardDescription>
        </div>
        <div className="flex flex-col sm:flex-row flex-wrap gap-2">
          <Input className="w-[280px]" aria-label="Buscar curso ou instituição" placeholder="Buscar curso ou instituição"
            value={searchInput} onChange={(e) => setSearchInput(e.target.value)} />
          <Select value={institutionId || "all"} onValueChange={(v) => setFilter("institution", v)}>
            <SelectTrigger className="w-[260px]" aria-label="Instituição"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todas as instituições</SelectItem>
              {institutions.data?.map((i) => <SelectItem key={i.id} value={i.id}>{i.name}</SelectItem>)}
            </SelectContent>
          </Select>
          <Select value={type || "all"} onValueChange={(v) => setFilter("type", v)}>
            <SelectTrigger className="w-[160px]" aria-label="Modalidade"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">SiSU e ProUni</SelectItem>
              <SelectItem value="sisu">SiSU</SelectItem>
              <SelectItem value="prouni">ProUni</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </CardHeader>
      <CardContent className="space-y-3">
        {query.isPlaceholderData && <p className="text-xs text-muted-foreground" role="status">Atualizando volumes…</p>}
        {query.isLoading && (
          <div className="flex items-center gap-2" role="status"><Loader2 className="h-5 w-5 animate-spin text-primary" />Carregando volumes…</div>
        )}
        {query.isError && (
          <div className="space-y-2">
            <p className="text-sm text-destructive">Não foi possível carregar os volumes MEC.</p>
            <Button variant="outline" size="sm" onClick={() => void query.refetch()}>Recarregar volumes</Button>
          </div>
        )}
        {data && (
          <>
            <Table aria-label="Volumes por oportunidade MEC" aria-busy={query.isPlaceholderData} className={query.isPlaceholderData ? "opacity-60" : undefined}>
              <TableHeader>
                <TableRow>
                  <TableHead>Curso</TableHead>
                  <TableHead>Instituição</TableHead>
                  <TableHead>Local/campus</TableHead>
                  <TableHead>Modalidade</TableHead>
                  {SORTABLE.map((col) => (
                    <TableHead key={col.order} className="text-right" aria-sort={order === col.order ? "descending" : "none"}>
                      <button type="button" className={order === col.order ? "font-semibold underline" : "hover:underline"}
                        onClick={() => setFilter("order", col.order)}>
                        {col.label}<span className="sr-only">, Ordenar por {col.sortLabel}</span>{order === col.order ? " ↓" : ""}
                      </button>
                    </TableHead>
                  ))}
                  <TableHead className="text-right">Usuários autenticados</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.unified_opportunity_id}>
                    <TableCell className="font-medium">{row.in_catalog && row.course_title ? row.course_title : "fora do catálogo atual"}</TableCell>
                    <TableCell>{row.institution_name ?? "—"}</TableCell>
                    <TableCell>{row.location ?? "—"}</TableCell>
                    <TableCell>{modalityLabel(row.type)}</TableCell>
                    {SORTABLE.map((col) => (
                      <TableCell key={col.order} className="text-right">
                        {col.order === "redirects" && !redirectMeasured ? <span title="Redirect não instrumentado no período">n/i</span> : col.pick(row).toLocaleString("pt-BR")}
                      </TableCell>
                    ))}
                    <TableCell className="text-right">{row.distinct_users.toLocaleString("pt-BR")}</TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && data.total_count === 0 && (
                  <TableRow>
                    <TableCell colSpan={9} className="text-center py-4 text-muted-foreground">Nenhuma oportunidade MEC com eventos no período e filtros atuais.</TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
            <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
              <span>
                {rows.length > 0
                  ? `${data.offset + 1}–${data.offset + rows.length} de ${data.total_count}`
                  : data.total_count > 0 ? `Nenhuma linha nesta página · ${data.total_count} no total` : "0 de 0"}
              </span>
              <div className="flex gap-2">
                <Button variant="outline" size="sm" disabled={page <= 1} onClick={() => setPage(page - 1)}>Anterior</Button>
                <Button variant="outline" size="sm" disabled={data.offset + MEC_VOLUMES_PAGE_SIZE >= data.total_count} onClick={() => setPage(page + 1)}>Próxima</Button>
              </div>
            </div>
            <p className="text-xs text-muted-foreground">
              {data.non_additive_notice} “Pessoas distintas” inclui usuários autenticados e sessões anônimas; não some linhas
              ou páginas para obter um total de pessoas.
            </p>
          </>
        )}
      </CardContent>
    </Card>
  );
}
