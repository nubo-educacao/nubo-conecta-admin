import { FormEvent, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  EducationalCourse,
  EducationalOpportunity,
  OpportunityType,
  getCampusFilterOptions,
  getCourseOpportunities,
  getEducationalCourses,
  getEducationalFilterOptions,
} from "@/services/educationalDataService";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { BookOpen, ChevronDown, ChevronLeft, ChevronRight, Loader2, Search } from "lucide-react";
import { cn } from "@/lib/utils";

const PAGE_SIZE = 20;

function OpportunityDetails({
  course,
  year,
  opportunityType,
}: {
  course: EducationalCourse;
  year?: number;
  opportunityType: OpportunityType;
}) {
  const query = useQuery({
    queryKey: ["course-opportunities", course.id, year, opportunityType],
    queryFn: () => getCourseOpportunities({ courseId: course.id, year, opportunityType }),
  });

  if (query.isLoading) {
    return <div className="flex items-center gap-2 p-5 text-sm text-slate-500"><Loader2 className="h-4 w-4 animate-spin" />Carregando oportunidades…</div>;
  }

  if (query.isError) {
    return <p className="p-5 text-sm text-red-600">Não foi possível carregar as oportunidades deste curso.</p>;
  }

  if (!query.data?.length) {
    return <p className="p-5 text-sm text-slate-500">Nenhuma oportunidade corresponde aos filtros atuais.</p>;
  }

  return (
    <div className="grid gap-3 border-t bg-slate-50/70 p-4 lg:grid-cols-2">
      {query.data.map((opportunity: EducationalOpportunity) => (
        <article key={opportunity.id} className="rounded-xl border bg-white p-4 [content-visibility:auto]">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <Badge variant={opportunity.opportunity_type === "sisu" ? "default" : "secondary"}>
              {opportunity.opportunity_type.toUpperCase()}
            </Badge>
            <span className="text-xs font-medium text-slate-500">{opportunity.year} · {opportunity.semester || "semestre não informado"}</span>
          </div>
          <dl className="mt-4 grid grid-cols-2 gap-3 text-sm">
            <div><dt className="text-xs text-slate-500">Turno</dt><dd className="mt-0.5 font-medium">{opportunity.shift || "—"}</dd></div>
            <div><dt className="text-xs text-slate-500">Nota de corte</dt><dd className="mt-0.5 font-medium">{opportunity.cutoff_score ?? "—"}</dd></div>
            <div><dt className="text-xs text-slate-500">Bolsa</dt><dd className="mt-0.5 font-medium">{opportunity.scholarship_type || "—"}</dd></div>
            <div><dt className="text-xs text-slate-500">Concorrência / cota</dt><dd className="mt-0.5 font-medium">{opportunity.concurrency_type || "—"}</dd></div>
          </dl>
        </article>
      ))}
    </div>
  );
}

export default function OpportunitiesCourses() {
  const [page, setPage] = useState(0);
  const [searchInput, setSearchInput] = useState("");
  const [search, setSearch] = useState("");
  const [institutionId, setInstitutionId] = useState("");
  const [campusId, setCampusId] = useState("");
  const [degree, setDegree] = useState("all");
  const [year, setYear] = useState("all");
  const [opportunityType, setOpportunityType] = useState<OpportunityType>("all");
  const [expandedCourseId, setExpandedCourseId] = useState<string | null>(null);

  const optionsQuery = useQuery({
    queryKey: ["educational-filter-options"],
    queryFn: getEducationalFilterOptions,
    staleTime: 5 * 60 * 1000,
  });

  const campusOptionsQuery = useQuery({
    queryKey: ["educational-campus-options", institutionId],
    queryFn: () => getCampusFilterOptions(institutionId),
    enabled: Boolean(institutionId),
    staleTime: 5 * 60 * 1000,
  });

  const selectedYear = year === "all" ? undefined : Number(year);
  const coursesQuery = useQuery({
    queryKey: ["educational-courses", page, search, institutionId, campusId, degree, selectedYear, opportunityType],
    queryFn: () => getEducationalCourses({
      page,
      pageSize: PAGE_SIZE,
      search,
      institutionId: institutionId || undefined,
      campusId: campusId || undefined,
      degree,
      year: selectedYear,
      opportunityType,
    }),
  });

  function submitSearch(event: FormEvent) {
    event.preventDefault();
    setPage(0);
    setExpandedCourseId(null);
    setSearch(searchInput.trim());
  }

  function resetPagination() {
    setPage(0);
    setExpandedCourseId(null);
  }

  const courses = coursesQuery.data?.data ?? [];
  const total = coursesQuery.data?.total ?? 0;

  return (
    <div className="space-y-6 p-4 sm:p-6">
      <header className="rounded-2xl border border-sky-100 bg-gradient-to-r from-sky-50 via-white to-white px-5 py-4">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-sky-700">Explorer do catálogo</p>
        <h1 className="mt-1 text-2xl font-semibold text-slate-900">Oportunidades & Cursos</h1>
        <p className="mt-1 text-sm text-slate-600">Filtre cursos no servidor e expanda somente o contexto que deseja inspecionar.</p>
      </header>

      <Card>
        <CardContent className="grid gap-3 p-4 md:grid-cols-2 xl:grid-cols-[minmax(230px,1.4fr)_1fr_1fr_1fr_120px_130px]">
          <form className="flex gap-2" onSubmit={submitSearch}>
            <Input aria-label="Buscar cursos e oportunidades" placeholder="Buscar com tolerância a acentos" value={searchInput} onChange={(event) => setSearchInput(event.target.value)} />
            <Button type="submit" variant="outline" size="icon" aria-label="Aplicar busca"><Search className="h-4 w-4" /></Button>
          </form>

          <Select value={institutionId || "all"} onValueChange={(value) => { setInstitutionId(value === "all" ? "" : value); setCampusId(""); resetPagination(); }}>
            <SelectTrigger aria-label="Filtrar por instituição"><SelectValue placeholder="Instituição" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todas as instituições</SelectItem>
              {(optionsQuery.data?.institutions ?? []).map((item) => <SelectItem key={item.id} value={item.id}>{item.name}</SelectItem>)}
            </SelectContent>
          </Select>

          <Select value={campusId || "all"} disabled={!institutionId} onValueChange={(value) => { setCampusId(value === "all" ? "" : value); resetPagination(); }}>
            <SelectTrigger aria-label="Filtrar por campus"><SelectValue placeholder={institutionId ? "Campus" : "Escolha a instituição"} /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todos os campus</SelectItem>
              {(campusOptionsQuery.data ?? []).map((item) => <SelectItem key={item.id} value={item.id}>{item.name} {item.state ? `· ${item.state}` : ""}</SelectItem>)}
            </SelectContent>
          </Select>

          <Select value={degree} onValueChange={(value) => { setDegree(value); resetPagination(); }}>
            <SelectTrigger aria-label="Filtrar por grau"><SelectValue placeholder="Grau" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todos os graus</SelectItem>
              {(optionsQuery.data?.degrees ?? []).map((item) => <SelectItem key={item} value={item}>{item}</SelectItem>)}
            </SelectContent>
          </Select>

          <Select value={year} onValueChange={(value) => { setYear(value); resetPagination(); }}>
            <SelectTrigger aria-label="Filtrar por ano"><SelectValue placeholder="Ano" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todos</SelectItem>
              {(optionsQuery.data?.years ?? []).map((item) => <SelectItem key={item} value={String(item)}>{item}</SelectItem>)}
            </SelectContent>
          </Select>

          <Select value={opportunityType} onValueChange={(value: OpportunityType) => { setOpportunityType(value); resetPagination(); }}>
            <SelectTrigger aria-label="Filtrar por tipo"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">SiSU + ProUni</SelectItem>
              <SelectItem value="sisu">SiSU</SelectItem>
              <SelectItem value="prouni">ProUni</SelectItem>
            </SelectContent>
          </Select>
        </CardContent>
      </Card>

      <div className="flex items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-slate-900">Cursos encontrados</h2>
          <p className="text-sm text-slate-500" aria-live="polite">{total.toLocaleString("pt-BR")} cursos neste recorte</p>
        </div>
        {coursesQuery.isFetching && !coursesQuery.isLoading && <Loader2 className="h-4 w-4 animate-spin text-sky-600" aria-label="Atualizando resultados" />}
      </div>

      {coursesQuery.isLoading ? (
        <div className="space-y-3">{Array.from({ length: 6 }).map((_, index) => <Skeleton key={index} className="h-24 w-full" />)}</div>
      ) : coursesQuery.isError ? (
        <p className="rounded-xl border border-red-100 bg-red-50 p-6 text-sm text-red-700">Não foi possível consultar o explorer de cursos.</p>
      ) : courses.length === 0 ? (
        <div className="rounded-2xl border border-dashed p-10 text-center">
          <BookOpen className="mx-auto h-7 w-7 text-slate-400" />
          <p className="mt-3 text-sm text-slate-500">Nenhum curso corresponde aos filtros aplicados.</p>
        </div>
      ) : (
        <div className="space-y-3">
          {courses.map((course) => {
            const expanded = expandedCourseId === course.id;
            return (
              <Card key={course.id} className="overflow-hidden [content-visibility:auto]">
                <button
                  type="button"
                  aria-expanded={expanded}
                  onClick={() => setExpandedCourseId(expanded ? null : course.id)}
                  className="flex w-full items-center justify-between gap-5 p-4 text-left hover:bg-sky-50/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-sky-500 sm:p-5"
                >
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h3 className="font-semibold text-slate-900">{course.course_name}</h3>
                      {course.degree_type && <Badge variant="outline">{course.degree_type}</Badge>}
                    </div>
                    <p className="mt-1 truncate text-sm text-slate-600">{course.institution_name} · {course.campus_name}</p>
                    <p className="mt-1 text-xs text-slate-400">{[course.city, course.state].filter(Boolean).join(" · ")} {course.course_code ? `· Curso ${course.course_code}` : ""}</p>
                  </div>
                  <div className="flex shrink-0 items-center gap-3">
                    <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700">{course.opportunity_count} oportunidades</span>
                    <ChevronDown className={cn("h-5 w-5 text-slate-400 transition-transform", expanded && "rotate-180")} />
                  </div>
                </button>
                {expanded && <OpportunityDetails course={course} year={selectedYear} opportunityType={opportunityType} />}
              </Card>
            );
          })}
        </div>
      )}

      <div className="flex items-center justify-between border-t pt-4">
        <Button variant="outline" size="sm" onClick={() => setPage((value) => Math.max(0, value - 1))} disabled={page === 0 || coursesQuery.isFetching}><ChevronLeft className="mr-1 h-4 w-4" />Anterior</Button>
        <span className="text-sm text-slate-500">Página {page + 1}</span>
        <Button variant="outline" size="sm" onClick={() => setPage((value) => value + 1)} disabled={(page + 1) * PAGE_SIZE >= total || coursesQuery.isFetching}>Próxima<ChevronRight className="ml-1 h-4 w-4" /></Button>
      </div>
    </div>
  );
}
