import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
    Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Badge } from "@/components/ui/badge";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import { StatCard } from "@/components/analytics/StatCard";
import { Info, MousePointerClick, UserPlus, Sparkles, FileCheck, Settings2 } from "lucide-react";
import {
    getCampaigns,
    getChannels,
    getChannelPerformance,
    type GroupPerformance,
    type LinkPerformance,
} from "@/services/channelsService";
import ChannelEntityManager from "@/components/channels/ChannelEntityManager";

// Canais & Campanhas — TP-7 7E task 16 / ADR-0028.
//
// A camada em que canal é SUJEITO: "qual campanha performa melhor?". O recorte
// em que canal é adjetivo ("quem veio deste canal?") são os filtros nas telas
// existentes, escopo separado da mesma ADR.

/**
 * Taxa ausente NÃO é zero.
 *
 * Cliques só passaram a ser gravados em 13/08/2026; cadastros atribuídos
 * existem desde março, vindos do backfill. Imprimir 0% num link que trouxe 50
 * cadastros seria mentira, e seria a primeira coisa que o marketing veria.
 */
function Rate({ value, hasClicks }: { value: number | null; hasClicks: boolean }) {
    if (value === null) {
        return (
            <span className="text-xs text-muted-foreground" title={
                hasClicks
                    ? "Sem cadastros atribuídos no período."
                    : "Sem dados de clique para este link — a medição começou depois."
            }>
                —
            </span>
        );
    }
    return <span className="font-medium">{value.toLocaleString("pt-BR")}%</span>;
}

function GroupTable({ rows, label }: { rows: GroupPerformance[]; label: string }) {
    return (
        <Table>
            <TableHeader>
                <TableRow>
                    <TableHead>{label}</TableHead>
                    <TableHead className="text-right">Links</TableHead>
                    <TableHead className="text-right">Cliques</TableHead>
                    <TableHead className="text-right">Cadastros</TableHead>
                    <TableHead className="text-right">Conversão</TableHead>
                </TableRow>
            </TableHeader>
            <TableBody>
                {rows.length === 0 ? (
                    <TableRow>
                        <TableCell colSpan={5} className="h-20 text-center text-muted-foreground">
                            Sem dados.
                        </TableCell>
                    </TableRow>
                ) : (
                    rows.map((r) => (
                        <TableRow key={`${r.name}-${r.category ?? ""}`}>
                            <TableCell className="font-medium">
                                {r.name}
                                {r.category && r.category !== "—" && (
                                    <span className="ml-2 text-xs text-muted-foreground">{r.category}</span>
                                )}
                            </TableCell>
                            <TableCell className="text-right text-muted-foreground">{r.links}</TableCell>
                            <TableCell className="text-right">
                                {r.clicks.toLocaleString("pt-BR")}
                            </TableCell>
                            <TableCell className="text-right font-medium">
                                {r.signups.toLocaleString("pt-BR")}
                            </TableCell>
                            <TableCell className="text-right">
                                <Rate value={r.conversion_rate} hasClicks={r.clicks > 0} />
                            </TableCell>
                        </TableRow>
                    ))
                )}
            </TableBody>
        </Table>
    );
}

export default function Channels() {
    const [range] = useState<{ since: string | null; until: string | null }>({
        since: null,
        until: null,
    });
    const [tab, setTab] = useState("campaign");
    const queryClient = useQueryClient();

    const { data, isLoading, error } = useQuery({
        queryKey: ["channel-performance", range],
        queryFn: () => getChannelPerformance(range.since, range.until),
        staleTime: 1000 * 60 * 5,
    });
    const { data: campaigns = [] } = useQuery({ queryKey: ["campaigns"], queryFn: getCampaigns });
    const { data: channels = [] } = useQuery({ queryKey: ["channels"], queryFn: () => getChannels(false) });

    if (isLoading) {
        return (
            <div className="container space-y-6 py-6 px-3 sm:px-4 lg:px-8">
                <Skeleton className="h-9 w-64" />
                <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
                    {[...Array(4)].map((_, i) => <Skeleton key={i} className="h-32" />)}
                </div>
                <Skeleton className="h-96" />
            </div>
        );
    }

    if (error || !data) {
        return (
            <div className="container py-6 px-3 sm:px-4 lg:px-8">
                <Alert variant="destructive">
                    <AlertTitle>Não foi possível carregar</AlertTitle>
                    <AlertDescription>
                        Os dados de desempenho de canal não puderam ser lidos.
                    </AlertDescription>
                </Alert>
            </div>
        );
    }

    const { totals } = data;
    const firstClick = totals.first_click_at
        ? new Date(totals.first_click_at).toLocaleDateString("pt-BR")
        : null;

    return (
        <div className="container space-y-6 py-6 px-3 sm:px-4 lg:px-8">
            <div>
                <h1 className="font-display text-2xl font-bold">Canais &amp; Campanhas</h1>
                <p className="text-sm text-muted-foreground">
                    Desempenho por campanha, divulgador e plataforma.
                </p>
            </div>

            {/*
              O aviso de cold start é obrigatório enquanto não houver clique
              suficiente. Um dashboard que mostra 50 cadastros e conversão em
              branco, sem explicar, parece quebrado — e a explicação é simples:
              a medição de clique começou depois dos cadastros.
            */}
            {!totals.has_any_click_data ? (
                <Alert>
                    <Info className="h-4 w-4" />
                    <AlertTitle>Ainda não há dados de clique</AlertTitle>
                    <AlertDescription>
                        Os cadastros abaixo vêm da atribuição histórica. A medição de cliques
                        começou com os links novos, então a taxa de conversão só aparece
                        conforme eles forem distribuídos. Coluna em branco significa
                        &quot;ainda não medido&quot;, não &quot;zero&quot;.
                    </AlertDescription>
                </Alert>
            ) : (
                firstClick && (
                    <Alert>
                        <Info className="h-4 w-4" />
                        <AlertTitle>Cliques medidos a partir de {firstClick}</AlertTitle>
                        <AlertDescription>
                            Cadastros anteriores a essa data têm atribuição, mas não têm clique
                            correspondente. Linhas com conversão em branco são desse período —
                            não são conversão zero.
                        </AlertDescription>
                    </Alert>
                )
            )}

            <section className="grid grid-cols-2 gap-4 lg:grid-cols-4">
                <StatCard title="Cliques" value={totals.clicks.toLocaleString("pt-BR")} icon={MousePointerClick} variant="default" />
                <StatCard title="Cadastros" value={totals.signups.toLocaleString("pt-BR")} icon={UserPlus} variant="success" />
                <StatCard title="Com match" value={totals.matched.toLocaleString("pt-BR")} icon={Sparkles} variant="default" />
                <StatCard title="Candidaturas" value={totals.applied.toLocaleString("pt-BR")} icon={FileCheck} variant="default" />
            </section>

            <Tabs value={tab} onValueChange={setTab}>
                <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                    <TabsList>
                        <TabsTrigger value="campaign">Por campanha</TabsTrigger>
                        <TabsTrigger value="medium">Por tipo de canal</TabsTrigger>
                        <TabsTrigger value="platform">Por plataforma</TabsTrigger>
                        <TabsTrigger value="link">Por link</TabsTrigger>
                    </TabsList>
                    <Button
                        type="button"
                        variant={tab === "manage" ? "secondary" : "outline"}
                        onClick={() => setTab("manage")}
                        aria-pressed={tab === "manage"}
                    >
                        <Settings2 className="mr-2 h-4 w-4" />
                        Gerenciar cadastros
                    </Button>
                </div>

                <TabsContent value="campaign" className="rounded-md border">
                    <GroupTable rows={data.by_campaign} label="Campanha" />
                </TabsContent>
                <TabsContent value="medium" className="rounded-md border">
                    <GroupTable rows={data.by_medium} label="Tipo de canal" />
                </TabsContent>
                <TabsContent value="platform" className="rounded-md border">
                    <GroupTable rows={data.by_platform} label="Plataforma" />
                </TabsContent>

                <TabsContent value="link" className="rounded-md border">
                    <Table>
                        <TableHeader>
                            <TableRow>
                                <TableHead>Link</TableHead>
                                <TableHead>Campanha</TableHead>
                                <TableHead>Divulgador</TableHead>
                                <TableHead className="text-right">Cliques</TableHead>
                                <TableHead className="text-right">Cadastros</TableHead>
                                <TableHead className="text-right">Match</TableHead>
                                <TableHead className="text-right">Candidatura</TableHead>
                                <TableHead className="text-right">Conversão</TableHead>
                            </TableRow>
                        </TableHeader>
                        <TableBody>
                            {data.links.length === 0 ? (
                                <TableRow>
                                    <TableCell colSpan={8} className="h-24 text-center text-muted-foreground">
                                        Nenhum link cadastrado.
                                    </TableCell>
                                </TableRow>
                            ) : (
                                data.links.map((l: LinkPerformance) => (
                                    <TableRow key={l.link_id} className={l.archived ? "opacity-60" : undefined}>
                                        <TableCell className="font-medium">
                                            <div className="flex flex-col">
                                                <span>{l.nickname ?? l.code}</span>
                                                <code className="text-[10px] text-muted-foreground">{l.code}</code>
                                            </div>
                                        </TableCell>
                                        <TableCell>
                                            {l.campaign_name ?? (
                                                <span className="text-xs text-muted-foreground">sem campanha</span>
                                            )}
                                        </TableCell>
                                        <TableCell>
                                            <div className="flex flex-col">
                                                <span className="text-sm">{l.channel_name}</span>
                                                <Badge variant="secondary" className="mt-1 w-fit text-[10px]">
                                                    {l.medium}
                                                </Badge>
                                            </div>
                                        </TableCell>
                                        <TableCell className="text-right">
                                            {l.clicks.toLocaleString("pt-BR")}
                                        </TableCell>
                                        <TableCell className="text-right font-medium">
                                            {l.signups.toLocaleString("pt-BR")}
                                        </TableCell>
                                        <TableCell className="text-right text-muted-foreground">
                                            {l.matched.toLocaleString("pt-BR")}
                                        </TableCell>
                                        <TableCell className="text-right text-muted-foreground">
                                            {l.applied.toLocaleString("pt-BR")}
                                        </TableCell>
                                        <TableCell className="text-right">
                                            <Rate value={l.conversion_rate} hasClicks={l.has_click_data} />
                                        </TableCell>
                                    </TableRow>
                                ))
                            )}
                        </TableBody>
                    </Table>
                </TabsContent>

                <TabsContent value="manage" className="rounded-md border p-4">
                    <ChannelEntityManager
                        campaigns={campaigns}
                        channels={channels}
                        onChanged={() => {
                            queryClient.invalidateQueries({ queryKey: ["campaigns"] });
                            queryClient.invalidateQueries({ queryKey: ["channels"] });
                            queryClient.invalidateQueries({ queryKey: ["channel-links"] });
                            queryClient.invalidateQueries({ queryKey: ["channel-performance"] });
                        }}
                    />
                </TabsContent>
            </Tabs>
        </div>
    );
}
