import { useEffect, useState } from "react";
import {
    AlertDialog,
    AlertDialogAction,
    AlertDialogCancel,
    AlertDialogContent,
    AlertDialogDescription,
    AlertDialogFooter,
    AlertDialogHeader,
    AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Archive, Loader2, Trash2 } from "lucide-react";
import { toast } from "sonner";
import {
    getChannelEntityUsage,
    removeCampaign,
    removeChannel,
    type Campaign,
    type Channel,
    type ChannelEntityUsage,
} from "@/services/channelsService";

type EntityKind = "campaign" | "channel";

interface PendingAction {
    id: string;
    kind: EntityKind;
    name: string;
    links: number;
}

export default function ChannelEntityManager({
    campaigns,
    channels,
    onChanged,
}: {
    campaigns: Campaign[];
    channels: Channel[];
    onChanged: (kind: EntityKind, id: string) => void;
}) {
    const [usage, setUsage] = useState<ChannelEntityUsage | null>(null);
    const [pending, setPending] = useState<PendingAction | null>(null);
    const [saving, setSaving] = useState(false);

    useEffect(() => {
        let cancelled = false;
        void getChannelEntityUsage()
            .then((nextUsage) => {
                if (!cancelled) setUsage(nextUsage);
            })
            .catch(() => {
                if (!cancelled) {
                    toast.error("Não foi possível verificar os links vinculados.");
                    setUsage({ campaignLinks: {}, channelLinks: {} });
                }
            });
        return () => { cancelled = true; };
    }, [campaigns, channels]);

    const confirm = async () => {
        if (!pending) return;
        setSaving(true);
        try {
            const result = pending.kind === "campaign"
                ? await removeCampaign(pending.id, pending.links > 0)
                : await removeChannel(pending.id, pending.links > 0);
            const noun = pending.kind === "campaign" ? "Campanha" : "Divulgador";
            toast.success(
                result === "deleted"
                    ? `${noun} excluído permanentemente.`
                    : `${noun} arquivado e removido das listas de novos links.`,
            );
            onChanged(pending.kind, pending.id);
            setPending(null);
        } catch {
            toast.error("Não foi possível concluir a ação.");
        } finally {
            setSaving(false);
        }
    };

    const rows = (
        kind: EntityKind,
        items: Array<Campaign | Channel>,
        counts: Record<string, number>,
    ) => items.map((item) => {
        const links = counts[item.id] ?? 0;
        const willArchive = links > 0;
        return (
            <div key={item.id} className="flex items-center justify-between gap-3 py-2">
                <div className="min-w-0">
                    <p className="truncate text-sm font-medium">{item.name}</p>
                    <p className="text-xs text-muted-foreground">
                        {links === 0 ? "Sem links: pode ser excluído." : `${links} ${links === 1 ? "link" : "links"}: será arquivado.`}
                    </p>
                </div>
                <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    disabled={!usage}
                    onClick={() => setPending({ id: item.id, kind, name: item.name, links })}
                    title={willArchive ? "Arquivar" : "Excluir"}
                >
                    {willArchive ? <Archive className="h-4 w-4" /> : <Trash2 className="h-4 w-4 text-destructive" />}
                    <span className="ml-1">{willArchive ? "Arquivar" : "Excluir"}</span>
                </Button>
            </div>
        );
    });

    const actionLabel = pending?.links ? "Arquivar" : "Excluir";
    const noun = pending?.kind === "campaign" ? "campanha" : "divulgador";

    return (
        <>
            <div className="rounded-lg border bg-muted/30 p-3">
                <p className="text-xs font-semibold">Gerenciar campanhas e divulgadores</p>
                <p className="mt-1 text-xs text-muted-foreground">
                    Sem links, o cadastro é excluído. Com histórico, ele é arquivado e deixa de aparecer aqui.
                </p>
                <div className="mt-3 divide-y">
                    <div className="py-2">
                        <p className="text-xs font-medium text-muted-foreground">Campanhas</p>
                        {usage ? rows("campaign", campaigns, usage.campaignLinks) : <p className="mt-2 text-xs text-muted-foreground">Verificando vínculos…</p>}
                    </div>
                    <div className="py-2">
                        <p className="text-xs font-medium text-muted-foreground">Divulgadores</p>
                        {usage ? rows("channel", channels, usage.channelLinks) : <p className="mt-2 text-xs text-muted-foreground">Verificando vínculos…</p>}
                    </div>
                </div>
            </div>

            <AlertDialog open={Boolean(pending)} onOpenChange={(open) => !open && !saving && setPending(null)}>
                <AlertDialogContent>
                    <AlertDialogHeader>
                        <AlertDialogTitle>{actionLabel} {noun}?</AlertDialogTitle>
                        <AlertDialogDescription>
                            {pending?.links
                                ? `“${pending.name}” possui ${pending.links} ${pending.links === 1 ? "link" : "links"}. O histórico será preservado, mas o cadastro não aparecerá em novos links.`
                                : `“${pending?.name}” não possui links e será excluído permanentemente.`}
                        </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                        <AlertDialogCancel disabled={saving}>Cancelar</AlertDialogCancel>
                        <AlertDialogAction onClick={confirm} disabled={saving}>
                            {saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                            {actionLabel}
                        </AlertDialogAction>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialog>
        </>
    );
}
