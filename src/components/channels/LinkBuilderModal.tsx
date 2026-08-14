import { useState, useMemo } from "react";
import {
    Dialog,
    DialogContent,
    DialogDescription,
    DialogHeader,
    DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
    Select,
    SelectContent,
    SelectGroup,
    SelectItem,
    SelectLabel,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import { Loader2, Link as LinkIcon } from "lucide-react";
import { toast } from "sonner";
import {
    buildLinkCode,
    buildShareUrl,
    createChannelLink,
    deriveUtms,
    type Campaign,
    type Channel,
    type Platform,
    type ChannelMedium,
} from "@/services/channelsService";
import { QuickCreateCampaign, QuickCreateChannel } from "./QuickCreate";
import ChannelEntityManager from "./ChannelEntityManager";

// Construtor de links — TP-7 7D task 12.
//
// A regra do documento de governança, tornada estrutural aqui: NENHUM campo que
// vira UTM é digitável. São três seleções — campanha, divulgador, plataforma —
// e os cinco utm_* saem derivados delas.
//
// O que se digita é apenas o apelido (para achar o link depois) e o caminho de
// destino. Foi a digitação livre que produziu `dudinhanubo`, `ailanubo` e
// `felipebritonubo` como strings soltas na base, e "Canal: Não definido" na
// maioria dos registros.

interface LinkBuilderModalProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    campaigns: Campaign[];
    channels: Channel[];
    platforms: Platform[];
    mediums: ChannelMedium[];
    onCreated: () => void;
}

export default function LinkBuilderModal({
    open,
    onOpenChange,
    campaigns,
    channels,
    platforms,
    mediums,
    onCreated,
}: LinkBuilderModalProps) {
    const [campaignId, setCampaignId] = useState<string>("none");
    const [channelId, setChannelId] = useState<string>("");
    const [platformSlug, setPlatformSlug] = useState<string>("none");
    const [nickname, setNickname] = useState("");
    const [destination, setDestination] = useState("/");
    const [saving, setSaving] = useState(false);
    const [managingEntities, setManagingEntities] = useState(false);

    const campaign = campaigns.find((c) => c.id === campaignId) ?? null;
    const channel = channels.find((c) => c.id === channelId) ?? null;
    const platform = platforms.find((p) => p.slug === platformSlug) ?? null;

    // Plataformas agrupadas pela categoria. A categoria ("Canal", no vocabulário
    // do marketing) é DERIVADA e nunca digitada — é o que elimina o campo em
    // branco que hoje aparece como "Não definido".
    const grouped = useMemo(() => {
        return platforms.reduce<Record<string, Platform[]>>((acc, p) => {
            (acc[p.category] ??= []).push(p);
            return acc;
        }, {});
    }, [platforms]);

    const preview = useMemo(() => {
        if (!channel) return null;
        const code = buildLinkCode(campaign?.slug ?? null, channel.slug, platform?.slug ?? null);
        return {
            code,
            url: buildShareUrl(code),
            utms: deriveUtms({
                campaignSlug: campaign?.slug ?? null,
                channelSlug: channel.slug,
                channelType: channel.type,
                platformSlug: platform?.slug ?? null,
            }),
        };
    }, [campaign, channel, platform]);

    const reset = () => {
        setCampaignId("none");
        setChannelId("");
        setPlatformSlug("none");
        setNickname("");
        setDestination("/");
    };

    const handleSubmit = async () => {
        if (!channel) return;
        setSaving(true);
        try {
            await createChannelLink({
                campaign,
                channel,
                platform,
                nickname,
                destinationPath: destination,
            });
            toast.success("Link criado");
            reset();
            onOpenChange(false);
            onCreated();
        } catch (err: any) {
            // 23505 = code duplicado. Não é erro do usuário: significa que a
            // mesma combinação já existe, e reaproveitar é o certo.
            if (err?.code === "23505") {
                toast.error("Já existe um link com essa combinação. Use o da biblioteca.");
            } else {
                toast.error("Não foi possível criar o link.");
                console.error(err);
            }
        } finally {
            setSaving(false);
        }
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
                <DialogHeader>
                    <DialogTitle className="flex items-center gap-2">
                        <LinkIcon className="h-5 w-5" />
                        Novo link de divulgação
                    </DialogTitle>
                    <DialogDescription>
                        Escolha campanha, divulgador e plataforma. Os parâmetros de
                        rastreamento são preenchidos automaticamente.
                    </DialogDescription>
                </DialogHeader>

                <div className="grid gap-4 py-2">
                    <div className="grid gap-2">
                        <Label>Campanha</Label>
                        <Select value={campaignId} onValueChange={setCampaignId}>
                            <SelectTrigger>
                                <SelectValue placeholder="Selecione" />
                            </SelectTrigger>
                            <SelectContent>
                                <SelectItem value="none">Sem campanha</SelectItem>
                                {campaigns.map((c) => (
                                    <SelectItem key={c.id} value={c.id}>
                                        {c.name}
                                    </SelectItem>
                                ))}
                            </SelectContent>
                        </Select>
                        <p className="text-xs text-muted-foreground">
                            O objetivo que agrupa os links. Sem ela, o link não some — só
                            não entra em nenhum total.
                        </p>
                        {/* Criar sem sair do fluxo: mandar a pessoa para outra tela
                            no meio da criação de um link é como o cadastro de
                            divulgador acabou espalhado em dois lugares. */}
                        <QuickCreateCampaign
                            onCreated={(c) => {
                                onCreated();
                                setCampaignId(c.id);
                            }}
                        />
                    </div>

                    <div className="grid gap-2">
                        <Label>
                            Divulgador <span className="text-destructive">*</span>
                        </Label>
                        <Select value={channelId} onValueChange={setChannelId}>
                            <SelectTrigger>
                                <SelectValue placeholder="Selecione quem vai divulgar" />
                            </SelectTrigger>
                            <SelectContent>
                                {channels.map((c) => (
                                    <SelectItem key={c.id} value={c.id}>
                                        {c.name}
                                        <span className="ml-2 text-xs text-muted-foreground">
                                            {c.type}
                                        </span>
                                    </SelectItem>
                                ))}
                            </SelectContent>
                        </Select>

                        <QuickCreateChannel
                            mediums={mediums}
                            onCreated={(c) => {
                                onCreated();
                                setChannelId(c.id);
                            }}
                        />
                    </div>

                    <div className="grid gap-2">
                        <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            className="h-auto justify-start p-0 text-xs"
                            onClick={() => setManagingEntities((current) => !current)}
                        >
                            {managingEntities ? "Fechar gestão de campanhas e divulgadores" : "Gerenciar campanhas e divulgadores"}
                        </Button>
                        {managingEntities && (
                            <ChannelEntityManager
                                campaigns={campaigns}
                                channels={channels}
                                onChanged={(kind, id) => {
                                    if (kind === "campaign" && campaignId === id) setCampaignId("none");
                                    if (kind === "channel" && channelId === id) setChannelId("");
                                    onCreated();
                                }}
                            />
                        )}
                    </div>

                    <div className="grid gap-2">
                        <Label>Plataforma</Label>
                        <Select value={platformSlug} onValueChange={setPlatformSlug}>
                            <SelectTrigger>
                                <SelectValue placeholder="Onde a peça será publicada" />
                            </SelectTrigger>
                            <SelectContent>
                                <SelectItem value="none">Não se aplica</SelectItem>
                                {Object.entries(grouped).map(([category, items]) => (
                                    <SelectGroup key={category}>
                                        <SelectLabel>{category}</SelectLabel>
                                        {items.map((p) => (
                                            <SelectItem key={p.slug} value={p.slug}>
                                                {p.name}
                                            </SelectItem>
                                        ))}
                                    </SelectGroup>
                                ))}
                            </SelectContent>
                        </Select>
                    </div>

                    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                        <div className="grid gap-2">
                            <Label>Apelido</Label>
                            <Input
                                value={nickname}
                                onChange={(e) => setNickname(e.target.value)}
                                placeholder="Como você vai achar este link depois"
                            />
                        </div>
                        <div className="grid gap-2">
                            <Label>Página de destino</Label>
                            <Input
                                value={destination}
                                onChange={(e) => setDestination(e.target.value)}
                                placeholder="/"
                            />
                        </div>
                    </div>

                    {/* Prévia: mostra exatamente o que vai ser gravado, antes de
                        gravar. O marketing precisa enxergar o resultado da
                        derivação, senão "campos preenchidos automaticamente" vira
                        caixa-preta. */}
                    {preview && (
                        <div className="rounded-lg border bg-muted/40 p-4">
                            <p className="mb-2 text-xs font-semibold uppercase text-muted-foreground">
                                Prévia
                            </p>
                            <code className="block break-all text-sm font-medium">
                                {preview.url}
                            </code>
                            <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-3">
                                {Object.entries(preview.utms).map(([key, value]) => (
                                    <div key={key} className="flex flex-col">
                                        <dt className="text-muted-foreground">{key}</dt>
                                        <dd className="font-medium">{value ?? "—"}</dd>
                                    </div>
                                ))}
                            </dl>
                        </div>
                    )}
                </div>

                <div className="flex justify-end gap-2">
                    <Button variant="outline" onClick={() => onOpenChange(false)} disabled={saving}>
                        Cancelar
                    </Button>
                    <Button onClick={handleSubmit} disabled={!channel || saving}>
                        {saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                        Criar link
                    </Button>
                </div>
            </DialogContent>
        </Dialog>
    );
}
