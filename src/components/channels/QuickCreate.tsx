import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
    Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select";
import { Loader2, Plus, X } from "lucide-react";
import { toast } from "sonner";
import {
    createCampaign, createChannel, slugify,
    type Campaign, type Channel, type ChannelMedium,
} from "@/services/channelsService";

// Criação inline de divulgador e campanha — TP-7 7D.
//
// Existe porque sem ela o Link Builder só usaria os 82 registros do backfill, e
// criar um divulgador novo continuaria exigindo a tela antiga de Influencers —
// que grava em `influencers`, tabela que não alimenta mais nada. Seriam dois
// caminhos de escrita divergindo em silêncio: o divulgador criado lá não
// apareceria aqui, e nunca apareceria, porque o backfill já passou.

export function QuickCreateChannel({
    mediums, onCreated,
}: {
    mediums: ChannelMedium[];
    onCreated: (channel: Channel) => void;
}) {
    const [open, setOpen] = useState(false);
    const [name, setName] = useState("");
    const [type, setType] = useState("");
    const [saving, setSaving] = useState(false);

    const submit = async () => {
        if (!name.trim() || !type) return;
        setSaving(true);
        try {
            const created = await createChannel({ name, type });
            toast.success(`Divulgador "${created.name}" criado`);
            onCreated(created);
            setName(""); setType(""); setOpen(false);
        } catch (err: any) {
            if (err?.code === "23505") {
                toast.error("Já existe um divulgador com esse nome.");
            } else {
                toast.error("Não foi possível criar o divulgador.");
                console.error(err);
            }
        } finally {
            setSaving(false);
        }
    };

    if (!open) {
        return (
            <Button variant="ghost" size="sm" className="h-auto p-0 text-xs" onClick={() => setOpen(true)}>
                <Plus className="mr-1 h-3 w-3" /> Criar divulgador
            </Button>
        );
    }

    return (
        <div className="rounded-lg border bg-muted/30 p-3">
            <div className="mb-2 flex items-center justify-between">
                <span className="text-xs font-semibold">Novo divulgador</span>
                <Button variant="ghost" size="sm" className="h-auto p-1" onClick={() => setOpen(false)}>
                    <X className="h-3 w-3" />
                </Button>
            </div>
            <div className="grid gap-2 sm:grid-cols-2">
                <div className="grid gap-1">
                    <Label className="text-xs">Nome</Label>
                    <Input
                        value={name}
                        onChange={(e) => setName(e.target.value)}
                        placeholder="Maria Eduarda Campos"
                        className="h-8 text-sm"
                    />
                </div>
                <div className="grid gap-1">
                    <Label className="text-xs">Tipo</Label>
                    <Select value={type} onValueChange={setType}>
                        <SelectTrigger className="h-8 text-sm">
                            <SelectValue placeholder="Selecione" />
                        </SelectTrigger>
                        <SelectContent>
                            {mediums.map((m) => (
                                <SelectItem key={m.slug} value={m.slug}>
                                    {m.name}
                                    <span className="ml-2 text-xs text-muted-foreground">
                                        {m.description}
                                    </span>
                                </SelectItem>
                            ))}
                        </SelectContent>
                    </Select>
                </div>
            </div>
            {/* O tipo vira utm_medium. É o campo que impede um disparo de CRM ser
                registrado como influencer — exatamente o que aconteceu na base
                legada, onde o maior gerador de cadastros era um disparo. */}
            {name.trim() && (
                <p className="mt-2 text-[11px] text-muted-foreground">
                    Identificador: <code>{slugify(name)}</code>
                </p>
            )}
            <Button size="sm" className="mt-2 h-8" onClick={submit} disabled={!name.trim() || !type || saving}>
                {saving && <Loader2 className="mr-2 h-3 w-3 animate-spin" />}
                Criar
            </Button>
        </div>
    );
}

export function QuickCreateCampaign({ onCreated }: { onCreated: (c: Campaign) => void }) {
    const [open, setOpen] = useState(false);
    const [name, setName] = useState("");
    const [objective, setObjective] = useState("");
    const [saving, setSaving] = useState(false);

    const submit = async () => {
        if (!name.trim()) return;
        setSaving(true);
        try {
            const created = await createCampaign({ name, objective });
            toast.success(`Campanha "${created.name}" criada`);
            onCreated(created);
            setName(""); setObjective(""); setOpen(false);
        } catch (err: any) {
            if (err?.code === "23505") {
                toast.error("Já existe uma campanha com este identificador. Altere o nome da campanha.");
            } else {
                toast.error("Não foi possível criar a campanha.");
                console.error(err);
            }
        } finally {
            setSaving(false);
        }
    };

    if (!open) {
        return (
            <Button variant="ghost" size="sm" className="h-auto p-0 text-xs" onClick={() => setOpen(true)}>
                <Plus className="mr-1 h-3 w-3" /> Criar campanha
            </Button>
        );
    }

    return (
        <div className="rounded-lg border bg-muted/30 p-3">
            <div className="mb-2 flex items-center justify-between">
                <span className="text-xs font-semibold">Nova campanha</span>
                <Button variant="ghost" size="sm" className="h-auto p-1" onClick={() => setOpen(false)}>
                    <X className="h-3 w-3" />
                </Button>
            </div>
            <div className="grid gap-2">
                <div className="grid gap-1">
                    <Label htmlFor="campaign-name" className="text-xs">Nome da campanha</Label>
                    <Input
                        id="campaign-name"
                        value={name}
                        onChange={(e) => setName(e.target.value)}
                        placeholder="Bolsa Insper 2026"
                        className="h-8 text-sm"
                    />
                </div>
                <div className="grid gap-1">
                    <Label htmlFor="campaign-objective" className="text-xs">Objetivo (opcional)</Label>
                    <Input
                        id="campaign-objective"
                        value={objective}
                        onChange={(e) => setObjective(e.target.value)}
                        placeholder="Ex.: inscrições no processo seletivo"
                        className="h-8 text-sm"
                    />
                </div>
            </div>
            {name.trim() && (
                <p className="mt-2 text-[11px] text-muted-foreground">
                    Identificador: <code>{slugify(name)}</code>
                </p>
            )}
            <Button size="sm" className="mt-2 h-8" onClick={submit} disabled={!name.trim() || saving}>
                {saving && <Loader2 className="mr-2 h-3 w-3 animate-spin" />}
                Criar
            </Button>
        </div>
    );
}
