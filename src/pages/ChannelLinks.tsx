import { useState, useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { StatCard } from "@/components/analytics/StatCard";
import { Skeleton } from "@/components/ui/skeleton";
import {
    Plus, Link as LinkIcon, Copy, Check, Archive, Search, Megaphone, Users,
} from "lucide-react";
import { toast } from "sonner";
import LinkBuilderModal from "@/components/channels/LinkBuilderModal";
import {
    archiveChannelLink,
    buildShareUrl,
    getCampaigns,
    getChannelLinks,
    getChannels,
    getPlatforms,
} from "@/services/channelsService";

// Biblioteca de links — TP-7 7D tasks 12–14.
//
// É o "volante" que faltava: o modelo de canal existia desde a migration
// 20260812140000, mas sem esta tela criar um link para campanha nova exigia
// INSERT manual em channel_links.

export default function ChannelLinks() {
    const queryClient = useQueryClient();
    const [builderOpen, setBuilderOpen] = useState(false);
    const [search, setSearch] = useState("");
    const [copiedId, setCopiedId] = useState<string | null>(null);

    const { data: links, isLoading } = useQuery({
        queryKey: ["channel-links"],
        queryFn: () => getChannelLinks(false),
    });
    const { data: campaigns } = useQuery({ queryKey: ["campaigns"], queryFn: getCampaigns });
    const { data: channels } = useQuery({ queryKey: ["channels"], queryFn: () => getChannels(false) });
    const { data: platforms } = useQuery({ queryKey: ["platforms"], queryFn: getPlatforms });

    const filtered = useMemo(() => {
        const term = search.trim().toLowerCase();
        if (!term) return links ?? [];
        // Busca por apelido, código, campanha e divulgador: são os quatro jeitos
        // pelos quais alguém lembra de um link que criou semanas atrás.
        return (links ?? []).filter((l) =>
            [l.nickname, l.code, l.campaign_name, l.channel_name]
                .filter(Boolean)
                .some((f) => String(f).toLowerCase().includes(term)),
        );
    }, [links, search]);

    const stats = useMemo(() => {
        const all = links ?? [];
        return {
            total: all.length,
            campanhas: new Set(all.map((l) => l.campaign_id).filter(Boolean)).size,
            divulgadores: new Set(all.map((l) => l.channel_id)).size,
        };
    }, [links]);

    const copy = async (code: string, id: string) => {
        await navigator.clipboard.writeText(buildShareUrl(code));
        setCopiedId(id);
        toast.success("Link copiado");
        setTimeout(() => setCopiedId(null), 2000);
    };

    const archive = async (id: string, nickname: string | null) => {
        try {
            await archiveChannelLink(id);
            // Arquivar não quebra o link: /r/<code> continua resolvendo e
            // registrando clique. Só some da biblioteca.
            toast.success(`"${nickname ?? "Link"}" arquivado. O link continua funcionando.`);
            queryClient.invalidateQueries({ queryKey: ["channel-links"] });
        } catch {
            toast.error("Não foi possível arquivar.");
        }
    };

    return (
        <div className="container py-6 space-y-6 px-3 sm:px-4 lg:px-8">
            <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
                <div>
                    <h1 className="text-2xl font-bold font-display">Links de Divulgação</h1>
                    <p className="text-sm text-muted-foreground">
                        Crie links rastreáveis com parâmetros padronizados.
                    </p>
                </div>
                <Button onClick={() => setBuilderOpen(true)}>
                    <Plus className="mr-2 h-4 w-4" />
                    Novo link
                </Button>
            </div>

            <section className="grid grid-cols-1 gap-4 sm:grid-cols-3">
                <StatCard title="Links ativos" value={String(stats.total)} icon={LinkIcon} variant="default" />
                <StatCard title="Campanhas" value={String(stats.campanhas)} icon={Megaphone} variant="success" />
                <StatCard title="Divulgadores" value={String(stats.divulgadores)} icon={Users} variant="default" />
            </section>

            <div className="flex items-center gap-2 rounded-md border px-3">
                <Search className="h-4 w-4 text-muted-foreground" />
                <Input
                    value={search}
                    onChange={(e) => setSearch(e.target.value)}
                    placeholder="Buscar por apelido, código, campanha ou divulgador..."
                    className="border-0 focus-visible:ring-0"
                />
            </div>

            <div className="rounded-md border">
                <Table>
                    <TableHeader>
                        <TableRow>
                            <TableHead>Apelido</TableHead>
                            <TableHead>Campanha</TableHead>
                            <TableHead>Divulgador</TableHead>
                            <TableHead>Plataforma</TableHead>
                            <TableHead>Link</TableHead>
                            <TableHead className="text-right">Ações</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {isLoading ? (
                            [...Array(5)].map((_, i) => (
                                <TableRow key={i}>
                                    <TableCell colSpan={6}>
                                        <Skeleton className="h-8 w-full" />
                                    </TableCell>
                                </TableRow>
                            ))
                        ) : filtered.length === 0 ? (
                            <TableRow>
                                <TableCell colSpan={6} className="h-24 text-center text-muted-foreground">
                                    {search
                                        ? "Nenhum link encontrado."
                                        : "Nenhum link ainda. Crie o primeiro."}
                                </TableCell>
                            </TableRow>
                        ) : (
                            filtered.map((link) => (
                                <TableRow key={link.id}>
                                    <TableCell className="font-medium">
                                        {link.nickname ?? <span className="text-muted-foreground">—</span>}
                                    </TableCell>
                                    <TableCell>
                                        {link.campaign_name ?? (
                                            <span className="text-xs text-muted-foreground">sem campanha</span>
                                        )}
                                    </TableCell>
                                    <TableCell>
                                        <div className="flex flex-col">
                                            <span>{link.channel_name}</span>
                                            {link.channel_type && (
                                                <Badge variant="secondary" className="mt-1 w-fit text-[10px]">
                                                    {link.channel_type}
                                                </Badge>
                                            )}
                                        </div>
                                    </TableCell>
                                    <TableCell>
                                        {link.platform_name ? (
                                            <div className="flex flex-col">
                                                <span className="text-sm">{link.platform_name}</span>
                                                <span className="text-[10px] text-muted-foreground">
                                                    {link.platform_category}
                                                </span>
                                            </div>
                                        ) : (
                                            <span className="text-xs text-muted-foreground">—</span>
                                        )}
                                    </TableCell>
                                    <TableCell>
                                        <code className="rounded bg-muted px-2 py-1 text-xs">{link.code}</code>
                                    </TableCell>
                                    <TableCell className="text-right">
                                        <div className="flex justify-end gap-1">
                                            <Button
                                                variant="ghost"
                                                size="sm"
                                                onClick={() => copy(link.code, link.id)}
                                                title="Copiar link"
                                            >
                                                {copiedId === link.id ? (
                                                    <Check className="h-4 w-4 text-success" />
                                                ) : (
                                                    <Copy className="h-4 w-4" />
                                                )}
                                            </Button>
                                            <Button
                                                variant="ghost"
                                                size="sm"
                                                onClick={() => archive(link.id, link.nickname)}
                                                title="Arquivar (o link continua funcionando)"
                                            >
                                                <Archive className="h-4 w-4" />
                                            </Button>
                                        </div>
                                    </TableCell>
                                </TableRow>
                            ))
                        )}
                    </TableBody>
                </Table>
            </div>

            <LinkBuilderModal
                open={builderOpen}
                onOpenChange={setBuilderOpen}
                campaigns={campaigns ?? []}
                channels={channels ?? []}
                platforms={platforms ?? []}
                onCreated={() => queryClient.invalidateQueries({ queryKey: ["channel-links"] })}
            />
        </div>
    );
}
