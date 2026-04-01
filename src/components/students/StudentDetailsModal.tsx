
import {
    Dialog,
    DialogContent,
    DialogDescription,
    DialogHeader,
    DialogTitle,
} from "@/components/ui/dialog";
import { useQuery } from "@tanstack/react-query";
import { getStudentDetails } from "@/services/studentsService";
import { Loader2 } from "lucide-react";
import { ScrollArea } from "@/components/ui/scroll-area";

interface StudentDetailsModalProps {
    isOpen: boolean;
    onOpenChange: (open: boolean) => void;
    studentId: string | null;
}

export function StudentDetailsModal({ isOpen, onOpenChange, studentId }: StudentDetailsModalProps) {
    const { data: details, isLoading } = useQuery({
        queryKey: ["student-details", studentId],
        queryFn: () => (studentId ? getStudentDetails(studentId) : Promise.reject("No ID")),
        enabled: !!studentId && isOpen,
    });

    return (
        <Dialog open={isOpen} onOpenChange={onOpenChange}>
            <DialogContent className="max-w-4xl h-[90vh]">
                <DialogHeader>
                    <DialogTitle>Detalhes do Estudante</DialogTitle>
                    <DialogDescription>
                        Informações completas do perfil, preferências e notas.
                    </DialogDescription>
                </DialogHeader>

                {isLoading ? (
                    <div className="flex h-full items-center justify-center">
                        <Loader2 className="h-8 w-8 animate-spin text-primary" />
                    </div>
                ) : details ? (
                    <ScrollArea className="h-full pr-4">
                        <div className="space-y-6 pb-6">

                            {/* Profile Summary */}
                            <section>
                                <h3 className="text-lg font-semibold mb-2">Perfil</h3>
                                <div className="grid grid-cols-2 md:grid-cols-4 gap-4 p-4 border rounded-lg bg-slate-50 dark:bg-slate-900">
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Nome</span>
                                        <span className="font-medium">{details.profile?.full_name || "-"}</span>
                                    </div>
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Idade</span>
                                        <span className="font-medium">{details.profile?.age || "-"}</span>
                                    </div>
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Cidade</span>
                                        <span className="font-medium">{details.profile?.city || "-"}</span>
                                    </div>
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Escolaridade</span>
                                        <span className="font-medium">{details.profile?.education || "-"}</span>
                                    </div>
                                </div>
                            </section>

                            {/* Preferences */}
                            <section>
                                <h3 className="text-lg font-semibold mb-2">Preferências</h3>
                                <div className="grid grid-cols-1 md:grid-cols-2 gap-4 p-4 border rounded-lg">
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Interesses de Curso</span>
                                        <div className="flex flex-wrap gap-1 mt-1">
                                            {details.preferences?.course_interest?.map((c, i) => (
                                                <span key={i} className="px-2 py-1 bg-primary/10 rounded-md text-xs">{c}</span>
                                            )) || "-"}
                                        </div>
                                    </div>
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Turnos Preferidos</span>
                                        <div className="flex flex-wrap gap-1 mt-1">
                                            {details.preferences?.preferred_shifts?.map((s, i) => (
                                                <span key={i} className="px-2 py-1 bg-secondary rounded-md text-xs">{s}</span>
                                            )) || "-"}
                                        </div>
                                    </div>
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Universidade</span>
                                        <span className="font-medium capitalize">{details.preferences?.university_preference || "-"}</span>
                                    </div>
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Programa</span>
                                        <span className="font-medium capitalize">{details.preferences?.program_preference || "-"}</span>
                                    </div>
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Renda Familiar Per Capita</span>
                                        <span className="font-medium">
                                            {details.preferences?.family_income_per_capita
                                                ? `R$ ${details.preferences.family_income_per_capita.toFixed(2)}`
                                                : "-"}
                                        </span>
                                    </div>
                                    <div>
                                        <span className="text-xs text-muted-foreground block">Cotas</span>
                                        <div className="flex flex-wrap gap-1 mt-1">
                                            {details.preferences?.quota_types?.map((q, i) => (
                                                <span key={i} className="px-2 py-1 bg-muted rounded-md text-xs">{q}</span>
                                            )) || "-"}
                                        </div>
                                    </div>
                                </div>
                            </section>

                            {/* ENEM Scores */}
                            <section>
                                <h3 className="text-lg font-semibold mb-2">Notas do ENEM</h3>
                                {details.enem_scores.length === 0 ? (
                                    <p className="text-sm text-muted-foreground">Nenhuma nota registrada.</p>
                                ) : (
                                    <div className="overflow-x-auto rounded-lg border">
                                        <table className="w-full text-sm">
                                            <thead className="bg-muted">
                                                <tr>
                                                    <th className="px-4 py-2 text-left">Ano</th>
                                                    <th className="px-4 py-2 text-right">Linguagens</th>
                                                    <th className="px-4 py-2 text-right">Humanas</th>
                                                    <th className="px-4 py-2 text-right">Natureza</th>
                                                    <th className="px-4 py-2 text-right">Matemática</th>
                                                    <th className="px-4 py-2 text-right">Redação</th>
                                                </tr>
                                            </thead>
                                            <tbody>
                                                {details.enem_scores.map((score) => (
                                                    <tr key={score.id} className="border-t">
                                                        <td className="px-4 py-2 font-medium">{score.year}</td>
                                                        <td className="px-4 py-2 text-right">{score.nota_linguagens ?? "-"}</td>
                                                        <td className="px-4 py-2 text-right">{score.nota_ciencias_humanas ?? "-"}</td>
                                                        <td className="px-4 py-2 text-right">{score.nota_ciencias_natureza ?? "-"}</td>
                                                        <td className="px-4 py-2 text-right">{score.nota_matematica ?? "-"}</td>
                                                        <td className="px-4 py-2 text-right">{score.nota_redacao ?? "-"}</td>
                                                    </tr>
                                                ))}
                                            </tbody>
                                        </table>
                                    </div>
                                )}
                            </section>

                            {/* Favorites */}
                            <section>
                                <h3 className="text-lg font-semibold mb-2">Favoritos</h3>
                                {details.favorites.length === 0 ? (
                                    <p className="text-sm text-muted-foreground">Nenhum favorito registrado.</p>
                                ) : (
                                    <ul className="space-y-2">
                                        {details.favorites.map((fav) => (
                                            <li key={fav.id} className="p-3 border rounded-md flex justify-between items-center">
                                                <div>
                                                    {fav.course_id ? (
                                                        <span className="font-medium text-primary">Curso: {fav.courses?.name || "Curso ID: " + fav.course_id}</span>
                                                    ) : fav.partner_id ? (
                                                        <span className="font-medium text-secondary-foreground">Parceiro: {fav.partners?.name || "Parceiro ID: " + fav.partner_id}</span>
                                                    ) : (
                                                        <span>Item Desconhecido</span>
                                                    )}
                                                </div>
                                                <span className="text-xs text-muted-foreground">
                                                    Salvo em {new Date(fav.created_at).toLocaleDateString()}
                                                </span>
                                            </li>
                                        ))}
                                    </ul>
                                )}
                            </section>

                        </div>
                    </ScrollArea>
                ) : (
                    <div className="flex h-full items-center justify-center text-muted-foreground">
                        Não foi possível carregar os detalhes.
                    </div>
                )}
            </DialogContent>
        </Dialog>
    );
}
