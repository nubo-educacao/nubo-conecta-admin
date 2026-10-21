
import {
    Dialog,
    DialogContent,
} from "@/components/ui/dialog";
import { useQuery } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { getStudentDetails } from "@/services/studentsService";
import { Activity, Loader2, User, Heart } from "lucide-react";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

import { StudentModalHeader, studentModalClassName, studentTabsClassName } from './StudentModalHeader';

interface StudentDetailsModalProps {
    isOpen: boolean;
    onOpenChange: (open: boolean) => void;
    studentId: string | null;
    studentName?: string | null;
    onViewActivity?: () => void;
}

export function StudentDetailsModal({ isOpen, onOpenChange, studentId, studentName, onViewActivity }: StudentDetailsModalProps) {
    const [activeTab, setActiveTab] = useState("perfil");
    useEffect(() => { setActiveTab("perfil"); }, [studentId, isOpen]);
    const { data: details, isLoading, isFetching, refetch } = useQuery({
        queryKey: ["student-profile", studentId],
        queryFn: () => (studentId ? getStudentDetails(studentId, 0, { includeMatches: false }) : Promise.reject("No ID")),
        enabled: !!studentId && isOpen,
    });
    const sourceWarning = (source: keyof NonNullable<NonNullable<typeof details>['source_errors']>) =>
        details?.source_errors?.[source] ? (
            <div role="alert" className="space-y-2 rounded-lg border p-3">
                <p>{details.source_errors[source]}</p>
                <Button variant="outline" size="sm" disabled={isFetching} onClick={() => refetch()}>Tentar novamente</Button>
            </div>
        ) : null;

    return (
        <Dialog open={isOpen} onOpenChange={onOpenChange}>
            <DialogContent className={studentModalClassName}>
                <StudentModalHeader title="Perfil do estudante" studentName={studentName || details?.profile?.full_name}
                    description="Dados pessoais, preferências e favoritos"
                    action={onViewActivity && <Button aria-label="Ver atividade" variant="outline" size="sm" className="shrink-0 gap-2 rounded-lg" onClick={onViewActivity}>
                        <Activity aria-hidden="true" className="h-4 w-4" /><span className="hidden sm:inline">Ver atividade</span>
                        <span className="sr-only sm:hidden">Ver atividade</span>
                    </Button>} />

                {isLoading ? (
                    <div className="flex h-full items-center justify-center">
                        <Loader2 className="h-8 w-8 animate-spin text-primary" />
                    </div>
                ) : details ? (
                    <Tabs value={activeTab} onValueChange={setActiveTab} className="flex min-h-0 flex-1 flex-col overflow-hidden px-6 pb-6 pt-5 sm:px-8 sm:pb-8">
                        <TabsList className={studentTabsClassName + " mb-5 shrink-0 grid-cols-2"}>
                            <TabsTrigger value="perfil" className="flex items-center justify-center gap-2 py-2.5">
                                <User className="h-4 w-4" /> Perfil Geral
                            </TabsTrigger>
                            <TabsTrigger value="favoritos" className="flex items-center justify-center gap-2 py-2.5">
                                <Heart className="h-4 w-4 text-rose-500" /> Favoritos ({details.source_errors?.favorites ? "?" : details.favorites?.length || 0})
                            </TabsTrigger>
                        </TabsList>

                        <ScrollArea className="flex-1 pr-4">
                            {/* TAB 1: PERFIL GERAL */}
                            <TabsContent value="perfil" className="space-y-6 mt-0 pb-4">
                                {/* Profile Summary */}
                                <section>
                                    <h3 className="text-base font-semibold mb-3 text-slate-800 dark:text-slate-200">Dados Pessoais</h3>
                                    {sourceWarning('profile')}
                                    <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-y-5 gap-x-6 p-5 border rounded-xl bg-slate-50/60 dark:bg-slate-900/40">
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Nome</span>
                                            <span className="font-medium text-slate-900 dark:text-slate-100">{details.profile?.full_name || "-"}</span>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Idade</span>
                                            <span className="font-medium text-slate-900 dark:text-slate-100">{details.profile?.age ? `${details.profile.age} anos` : "-"}</span>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Raça / Etnia</span>
                                            <span className="font-medium text-slate-900 dark:text-slate-100">{details.profile?.race || "-"}</span>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Cidade / UF</span>
                                            <span className="font-medium text-slate-900 dark:text-slate-100">{details.profile?.city ? `${details.profile.city} - ${details.profile.state || ''}` : "-"}</span>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">WhatsApp</span>
                                            <span className="font-medium text-slate-900 dark:text-slate-100">{details.profile?.whatsapp || "-"}</span>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Estudante Nubo</span>
                                            <span className="font-medium text-slate-900 dark:text-slate-100">{details.profile?.is_nubo_student ? "Sim" : "Não"}</span>
                                        </div>
                                        <div className="sm:col-span-2 md:col-span-3">
                                            <span className="text-xs text-muted-foreground block mb-1">Escolaridade</span>
                                            <span className="font-medium text-slate-900 dark:text-slate-100">{details.profile?.education || "-"}</span>
                                        </div>
                                    </div>
                                </section>

                                {/* Preferences & Income */}
                                <section>
                                    <h3 className="text-base font-semibold mb-3 text-slate-800 dark:text-slate-200">Preferências & Renda</h3>
                                    {sourceWarning('preferences')}
                                    <div className="grid grid-cols-1 md:grid-cols-2 gap-y-5 gap-x-6 p-5 border rounded-xl bg-slate-50/60 dark:bg-slate-900/40">
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Interesses de Curso</span>
                                            <div className="flex flex-wrap gap-1.5 mt-1">
                                                {details.preferences?.course_interest && details.preferences.course_interest.length > 0 ? (
                                                    details.preferences.course_interest.map((c, i) => (
                                                        <span key={i} className="px-2.5 py-1 bg-primary/10 text-primary rounded-md text-xs font-medium">{c}</span>
                                                    ))
                                                ) : (
                                                    <span className="text-sm text-slate-600 dark:text-slate-400">-</span>
                                                )}
                                            </div>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Turnos Preferidos</span>
                                            <div className="flex flex-wrap gap-1.5 mt-1">
                                                {details.preferences?.preferred_shifts && details.preferences.preferred_shifts.length > 0 ? (
                                                    details.preferences.preferred_shifts.map((s, i) => (
                                                        <span key={i} className="px-2.5 py-1 bg-slate-200 dark:bg-slate-800 text-slate-800 dark:text-slate-200 rounded-md text-xs font-medium">{s}</span>
                                                    ))
                                                ) : (
                                                    <span className="text-sm text-slate-600 dark:text-slate-400">-</span>
                                                )}
                                            </div>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Universidade</span>
                                            <span className="font-medium capitalize text-slate-900 dark:text-slate-100">{details.preferences?.university_preference || "-"}</span>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Programa</span>
                                            <span className="font-medium capitalize text-slate-900 dark:text-slate-100">{details.preferences?.program_preference || "-"}</span>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Renda Familiar Per Capita</span>
                                            <span className="font-medium text-slate-900 dark:text-slate-100">
                                                {details.preferences?.family_income_per_capita
                                                    ? `R$ ${details.preferences.family_income_per_capita.toFixed(2)}`
                                                    : "-"}
                                            </span>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Cotas</span>
                                            <div className="flex flex-wrap gap-1.5 mt-1">
                                                {details.preferences?.quota_types && details.preferences.quota_types.length > 0 ? (
                                                    details.preferences.quota_types.map((q, i) => (
                                                        <span key={i} className="px-2.5 py-1 bg-slate-100 dark:bg-slate-800 border text-slate-700 dark:text-slate-300 rounded-md text-xs font-medium">{q}</span>
                                                    ))
                                                ) : (
                                                    <span className="text-sm text-slate-600 dark:text-slate-400">-</span>
                                                )}
                                            </div>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Local de Estudo Preferido</span>
                                            <span className="font-medium capitalize text-slate-900 dark:text-slate-100">{details.preferences?.location_preference || "-"}</span>
                                        </div>
                                        <div>
                                            <span className="text-xs text-muted-foreground block mb-1">Estado Preferido</span>
                                            <span className="font-medium uppercase text-slate-900 dark:text-slate-100">{details.preferences?.state_preference || "-"}</span>
                                        </div>
                                    </div>
                                </section>

                                {/* ENEM Scores */}
                                <section>
                                    <h3 className="text-base font-semibold mb-3 text-slate-800 dark:text-slate-200">Notas do ENEM</h3>
                                    {sourceWarning('enem_scores')}
                                    {details.source_errors?.enem_scores ? null : details.enem_scores.length === 0 ? (
                                        <div className="p-4 border rounded-xl bg-slate-50/60 dark:bg-slate-900/40 text-sm text-muted-foreground">
                                            Nenhuma nota registrada.
                                        </div>
                                    ) : (
                                        <div className="overflow-x-auto rounded-xl border">
                                            <table className="w-full text-sm">
                                                <thead className="bg-slate-100 dark:bg-slate-800 text-slate-700 dark:text-slate-300">
                                                    <tr>
                                                        <th className="px-4 py-2.5 text-left font-semibold">Ano</th>
                                                        <th className="px-4 py-2.5 text-right font-semibold">Linguagens</th>
                                                        <th className="px-4 py-2.5 text-right font-semibold">Humanas</th>
                                                        <th className="px-4 py-2.5 text-right font-semibold">Natureza</th>
                                                        <th className="px-4 py-2.5 text-right font-semibold">Matemática</th>
                                                        <th className="px-4 py-2.5 text-right font-semibold">Redação</th>
                                                    </tr>
                                                </thead>
                                                <tbody className="divide-y">
                                                    {details.enem_scores.map((score) => (
                                                        <tr key={score.id} className="hover:bg-slate-50/50 dark:hover:bg-slate-800/50">
                                                            <td className="px-4 py-2.5 font-medium">{score.year}</td>
                                                            <td className="px-4 py-2.5 text-right">{score.nota_linguagens ?? "-"}</td>
                                                            <td className="px-4 py-2.5 text-right">{score.nota_ciencias_humanas ?? "-"}</td>
                                                            <td className="px-4 py-2.5 text-right">{score.nota_ciencias_natureza ?? "-"}</td>
                                                            <td className="px-4 py-2.5 text-right">{score.nota_matematica ?? "-"}</td>
                                                            <td className="px-4 py-2.5 text-right">{score.nota_redacao ?? "-"}</td>
                                                        </tr>
                                                    ))}
                                                </tbody>
                                            </table>
                                        </div>
                                    )}
                                </section>
                            </TabsContent>

                            {/* FAVORITOS */}
                            <TabsContent value="favoritos" className="space-y-4 mt-0 pb-4">
                                <h3 className="text-base font-semibold text-slate-800 dark:text-slate-200">Oportunidades Favoritadas</h3>
                                {sourceWarning('favorites')}
                                {details.source_errors?.favorites ? null : details.favorites.length === 0 ? (
                                    <div className="p-5 border rounded-xl bg-slate-50/60 dark:bg-slate-900/40 text-sm text-muted-foreground">
                                        Nenhum favorito registrado.
                                    </div>
                                ) : (
                                    <ul className="space-y-2.5">
                                        {details.favorites.map((fav) => (
                                            <li key={fav.id} className="p-4 border rounded-xl flex justify-between items-center bg-white dark:bg-slate-900 shadow-sm">
                                                <div>
                                                    <span className="font-medium text-primary">
                                                        {fav.courses?.name || fav.partners?.name || `Oportunidade #${fav.course_id || fav.partner_id || fav.id}`}
                                                    </span>
                                                </div>
                                                <span className="text-xs text-muted-foreground">
                                                    Salvo em {new Date(fav.created_at).toLocaleDateString()}
                                                </span>
                                            </li>
                                        ))}
                                    </ul>
                                )}
                            </TabsContent>
                        </ScrollArea>
                    </Tabs>
                ) : (
                    <div role="alert" className="flex h-full flex-col gap-3 items-center justify-center text-muted-foreground">
                        Não foi possível carregar os detalhes.
                        <Button variant="outline" disabled={isFetching} onClick={() => refetch()}>Tentar novamente</Button>
                    </div>
                )}
            </DialogContent>
        </Dialog>
    );
}
