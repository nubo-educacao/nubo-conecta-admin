import { FormEvent, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  EducationalInstitution,
  EducationalSource,
  getEducationalFilterOptions,
  getEducationalInstitutions,
  getInstitutionCampuses,
} from "@/services/educationalDataService";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Building2, ChevronLeft, ChevronRight, MapPin, Search } from "lucide-react";
import { cn } from "@/lib/utils";

const INSTITUTIONS_PAGE_SIZE = 20;
const CAMPUS_PAGE_SIZE = 15;

function CountPill({ label, value }: { label: string; value: number }) {
  return (
    <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-700">
      {value.toLocaleString("pt-BR")} {label}
    </span>
  );
}

export default function InstitutionsCampus() {
  const [page, setPage] = useState(0);
  const [searchInput, setSearchInput] = useState("");
  const [search, setSearch] = useState("");
  const [state, setState] = useState("all");
  const [source, setSource] = useState<EducationalSource>("all");
  const [selectedInstitution, setSelectedInstitution] = useState<EducationalInstitution | null>(null);
  const [campusPage, setCampusPage] = useState(0);
  const [campusSearchInput, setCampusSearchInput] = useState("");
  const [campusSearch, setCampusSearch] = useState("");

  const filtersQuery = useQuery({
    queryKey: ["educational-filter-options"],
    queryFn: getEducationalFilterOptions,
    staleTime: 5 * 60 * 1000,
  });

  const institutionsQuery = useQuery({
    queryKey: ["educational-institutions", page, search, state, source],
    queryFn: () => getEducationalInstitutions({
      page,
      pageSize: INSTITUTIONS_PAGE_SIZE,
      search,
      state,
      source,
    }),
  });

  const campusesQuery = useQuery({
    queryKey: ["institution-campuses", selectedInstitution?.id, campusPage, campusSearch],
    queryFn: () => getInstitutionCampuses({
      institutionId: selectedInstitution!.id,
      page: campusPage,
      pageSize: CAMPUS_PAGE_SIZE,
      search: campusSearch,
    }),
    enabled: Boolean(selectedInstitution),
  });

  function submitSearch(event: FormEvent) {
    event.preventDefault();
    setPage(0);
    setSelectedInstitution(null);
    setSearch(searchInput.trim());
  }

  function selectInstitution(institution: EducationalInstitution) {
    setSelectedInstitution(institution);
    setCampusPage(0);
    setCampusSearch("");
    setCampusSearchInput("");
  }

  function submitCampusSearch(event: FormEvent) {
    event.preventDefault();
    setCampusPage(0);
    setCampusSearch(campusSearchInput.trim());
  }

  const institutions = institutionsQuery.data?.data ?? [];
  const institutionTotal = institutionsQuery.data?.total ?? 0;
  const campuses = campusesQuery.data?.data ?? [];
  const campusTotal = campusesQuery.data?.total ?? 0;

  return (
    <div className="space-y-6 p-4 sm:p-6">
      <header className="rounded-2xl border border-sky-100 bg-gradient-to-r from-sky-50 via-white to-white px-5 py-4">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-sky-700">Catálogo institucional</p>
        <h1 className="mt-1 text-2xl font-semibold text-slate-900">Instituições & Campus</h1>
        <p className="mt-1 text-sm text-slate-600">
          Encontre a instituição, confira o perfil MEC e navegue pelos campus sem carregar o catálogo inteiro.
        </p>
      </header>

      <Card>
        <CardContent className="grid gap-3 p-4 md:grid-cols-[minmax(220px,1fr)_160px_180px_auto]">
          <form className="flex gap-2" onSubmit={submitSearch}>
            <Input
              aria-label="Buscar instituição"
              placeholder="Nome ou código MEC"
              value={searchInput}
              onChange={(event) => setSearchInput(event.target.value)}
            />
            <Button type="submit" variant="outline" size="icon" aria-label="Aplicar busca">
              <Search className="h-4 w-4" />
            </Button>
          </form>
          <Select value={state} onValueChange={(value) => { setState(value); setPage(0); setSelectedInstitution(null); }}>
            <SelectTrigger aria-label="Filtrar por UF"><SelectValue placeholder="Todas as UFs" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todas as UFs</SelectItem>
              {(filtersQuery.data?.states ?? []).map((item) => <SelectItem key={item} value={item}>{item}</SelectItem>)}
            </SelectContent>
          </Select>
          <Select value={source} onValueChange={(value: EducationalSource) => { setSource(value); setPage(0); setSelectedInstitution(null); }}>
            <SelectTrigger aria-label="Filtrar por origem"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todas as origens</SelectItem>
              <SelectItem value="partner">Parceiras</SelectItem>
              <SelectItem value="mec">Cadastro MEC</SelectItem>
            </SelectContent>
          </Select>
          <div className="self-center text-sm text-slate-500" aria-live="polite">
            {institutionTotal.toLocaleString("pt-BR")} instituições
          </div>
        </CardContent>
      </Card>

      <div className="grid gap-5 xl:grid-cols-[minmax(340px,0.9fr)_minmax(520px,1.4fr)]">
        <Card className="overflow-hidden">
          <CardHeader className="border-b bg-slate-50/70 py-4">
            <CardTitle className="text-base">Instituições</CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            {institutionsQuery.isLoading ? (
              <div className="space-y-3 p-4">{Array.from({ length: 6 }).map((_, index) => <Skeleton key={index} className="h-24 w-full" />)}</div>
            ) : institutionsQuery.isError ? (
              <p className="p-6 text-center text-sm text-red-600">Não foi possível carregar as instituições.</p>
            ) : institutions.length === 0 ? (
              <p className="p-8 text-center text-sm text-slate-500">Nenhuma instituição corresponde aos filtros.</p>
            ) : (
              <div className="divide-y">
                {institutions.map((institution) => (
                  <button
                    key={institution.id}
                    type="button"
                    aria-pressed={selectedInstitution?.id === institution.id}
                    onClick={() => selectInstitution(institution)}
                    className={cn(
                      "block w-full p-4 text-left transition-colors [content-visibility:auto] hover:bg-sky-50/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-sky-500",
                      selectedInstitution?.id === institution.id && "bg-sky-50 shadow-[inset_3px_0_0_#38b1e4]",
                    )}
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <p className="font-semibold text-slate-900">{institution.name}</p>
                        <p className="mt-1 text-xs text-slate-500">MEC {institution.external_code || "sem código"} · {institution.state || "UF não informada"}</p>
                      </div>
                      {institution.is_partner && <Badge className="bg-sky-100 text-sky-800 hover:bg-sky-100">Parceira</Badge>}
                    </div>
                    <div className="mt-3 flex flex-wrap gap-1.5">
                      <CountPill label="campus" value={institution.campus_count} />
                      <CountPill label="cursos" value={institution.course_count} />
                      <CountPill label="opps abertas" value={institution.open_opportunities_count} />
                    </div>
                  </button>
                ))}
              </div>
            )}
            <div className="flex items-center justify-between border-t p-3">
              <Button variant="outline" size="sm" onClick={() => setPage((value) => Math.max(0, value - 1))} disabled={page === 0 || institutionsQuery.isFetching}>
                <ChevronLeft className="mr-1 h-4 w-4" /> Anterior
              </Button>
              <span className="text-xs text-slate-500">Página {page + 1}</span>
              <Button variant="outline" size="sm" onClick={() => setPage((value) => value + 1)} disabled={(page + 1) * INSTITUTIONS_PAGE_SIZE >= institutionTotal || institutionsQuery.isFetching}>
                Próxima <ChevronRight className="ml-1 h-4 w-4" />
              </Button>
            </div>
          </CardContent>
        </Card>

        <Card className="min-h-[520px] overflow-hidden">
          {!selectedInstitution ? (
            <div className="flex min-h-[520px] flex-col items-center justify-center px-8 text-center">
              <div className="rounded-2xl bg-sky-50 p-4 text-sky-700"><Building2 className="h-7 w-7" /></div>
              <h2 className="mt-4 text-lg font-semibold text-slate-900">Selecione uma instituição</h2>
              <p className="mt-1 max-w-sm text-sm text-slate-500">O perfil, o IGC e os campus relacionados aparecerão aqui.</p>
            </div>
          ) : (
            <>
              <CardHeader className="border-b bg-slate-50/70">
                <div className="flex flex-wrap items-start justify-between gap-4">
                  <div>
                    <p className="text-xs font-semibold uppercase tracking-wide text-sky-700">Instituição selecionada</p>
                    <CardTitle className="mt-1 text-xl">{selectedInstitution.name}</CardTitle>
                    <p className="mt-1 text-sm text-slate-500">Código MEC {selectedInstitution.external_code || "não informado"}</p>
                  </div>
                  <div className="rounded-xl border bg-white px-4 py-2 text-center">
                    <p className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">IGC</p>
                    <p className="text-xl font-semibold text-slate-900">{selectedInstitution.igc || "—"}</p>
                  </div>
                </div>
              </CardHeader>
              <CardContent className="space-y-4 p-4">
                <form className="flex gap-2" onSubmit={submitCampusSearch}>
                  <Input
                    aria-label="Buscar campus da instituição"
                    placeholder="Buscar campus por nome ou cidade"
                    value={campusSearchInput}
                    onChange={(event) => setCampusSearchInput(event.target.value)}
                  />
                  <Button type="submit" variant="outline"><Search className="mr-2 h-4 w-4" />Buscar</Button>
                </form>

                {campusesQuery.isLoading ? (
                  <div className="grid gap-3 md:grid-cols-2">{Array.from({ length: 4 }).map((_, index) => <Skeleton key={index} className="h-32 w-full" />)}</div>
                ) : campusesQuery.isError ? (
                  <p className="rounded-xl border border-red-100 bg-red-50 p-5 text-sm text-red-700">Não foi possível carregar os campus desta instituição.</p>
                ) : campuses.length === 0 ? (
                  <p className="rounded-xl border border-dashed p-8 text-center text-sm text-slate-500">Nenhum campus encontrado neste contexto.</p>
                ) : (
                  <div className="grid gap-3 md:grid-cols-2">
                    {campuses.map((campus) => (
                      <article key={campus.id} className="rounded-xl border bg-white p-4 [content-visibility:auto]">
                        <div className="flex items-start gap-3">
                          <MapPin className="mt-0.5 h-4 w-4 shrink-0 text-sky-600" />
                          <div>
                            <h3 className="font-semibold text-slate-900">{campus.name}</h3>
                            <p className="mt-1 text-xs text-slate-500">{[campus.city, campus.state].filter(Boolean).join(" · ") || "Localização não informada"}</p>
                            <p className="mt-1 text-xs text-slate-400">Código {campus.external_code || "—"}</p>
                          </div>
                        </div>
                        <div className="mt-4 flex flex-wrap gap-2">
                          <CountPill label="cursos" value={campus.course_count} />
                          <CountPill label="oportunidades" value={campus.opportunity_count} />
                        </div>
                      </article>
                    ))}
                  </div>
                )}

                <div className="flex items-center justify-between border-t pt-3">
                  <span className="text-xs text-slate-500">{campusTotal.toLocaleString("pt-BR")} campus</span>
                  <div className="flex items-center gap-2">
                    <Button variant="outline" size="sm" onClick={() => setCampusPage((value) => Math.max(0, value - 1))} disabled={campusPage === 0 || campusesQuery.isFetching}><ChevronLeft className="h-4 w-4" /></Button>
                    <span className="text-xs text-slate-500">Página {campusPage + 1}</span>
                    <Button variant="outline" size="sm" onClick={() => setCampusPage((value) => value + 1)} disabled={(campusPage + 1) * CAMPUS_PAGE_SIZE >= campusTotal || campusesQuery.isFetching}><ChevronRight className="h-4 w-4" /></Button>
                  </div>
                </div>
              </CardContent>
            </>
          )}
        </Card>
      </div>
    </div>
  );
}
