import { useState, useEffect } from "react";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from "@/components/ui/select";
import { ImportantDate, DATE_TYPE_LABELS, DateType } from "@/services/calendarService";

interface DateModalProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    date?: ImportantDate;
    onSubmit: (data: {
        title: string;
        description?: string;
        start_date: string;
        end_date?: string;
        type: string;
    }) => Promise<void>;
}

export default function DateModal({ open, onOpenChange, date, onSubmit }: DateModalProps) {
    const [title, setTitle] = useState("");
    const [description, setDescription] = useState("");
    const [startDate, setStartDate] = useState("");
    const [endDate, setEndDate] = useState("");
    const [type, setType] = useState<string>("general");
    const [loading, setLoading] = useState(false);

    useEffect(() => {
        if (date) {
            setTitle(date.title);
            setDescription(date.description || "");
            // Format the ISO date to datetime-local input format
            setStartDate(formatForInput(date.start_date));
            setEndDate(date.end_date ? formatForInput(date.end_date) : "");
            setType(date.type);
        } else {
            setTitle("");
            setDescription("");
            setStartDate("");
            setEndDate("");
            setType("general");
        }
    }, [date, open]);

    const formatForInput = (isoStr: string) => {
        const d = new Date(isoStr);
        // Format: YYYY-MM-DDTHH:mm
        const year = d.getFullYear();
        const month = String(d.getMonth() + 1).padStart(2, "0");
        const day = String(d.getDate()).padStart(2, "0");
        const hours = String(d.getHours()).padStart(2, "0");
        const minutes = String(d.getMinutes()).padStart(2, "0");
        return `${year}-${month}-${day}T${hours}:${minutes}`;
    };

    const handleSubmit = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);

        try {
            await onSubmit({
                title,
                description: description || undefined,
                start_date: new Date(startDate).toISOString(),
                end_date: endDate ? new Date(endDate).toISOString() : undefined,
                type,
            });
            onOpenChange(false);
        } catch {
            // Error is handled by the parent
        } finally {
            setLoading(false);
        }
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="sm:max-w-lg">
                <DialogHeader>
                    <DialogTitle>
                        {date ? "Editar Data" : "Adicionar Data"}
                    </DialogTitle>
                </DialogHeader>
                <form onSubmit={handleSubmit} className="space-y-4 py-4">
                    <div className="space-y-2">
                        <Label htmlFor="title">Título *</Label>
                        <Input
                            id="title"
                            value={title}
                            onChange={(e) => setTitle(e.target.value)}
                            placeholder="Ex: Inscrições Sisu 2026"
                            required
                        />
                    </div>

                    <div className="space-y-2">
                        <Label htmlFor="description">Descrição</Label>
                        <textarea
                            id="description"
                            value={description}
                            onChange={(e) => setDescription(e.target.value)}
                            placeholder="Descrição detalhada da data..."
                            className="flex min-h-[80px] w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
                        />
                    </div>

                    <div className="grid grid-cols-2 gap-4">
                        <div className="space-y-2">
                            <Label htmlFor="start_date">Data Início *</Label>
                            <Input
                                id="start_date"
                                type="datetime-local"
                                value={startDate}
                                onChange={(e) => setStartDate(e.target.value)}
                                required
                            />
                        </div>
                        <div className="space-y-2">
                            <Label htmlFor="end_date">Data Fim</Label>
                            <Input
                                id="end_date"
                                type="datetime-local"
                                value={endDate}
                                onChange={(e) => setEndDate(e.target.value)}
                            />
                        </div>
                    </div>

                    <div className="space-y-2">
                        <Label htmlFor="type">Tipo *</Label>
                        <Select value={type} onValueChange={setType}>
                            <SelectTrigger>
                                <SelectValue placeholder="Selecione o tipo" />
                            </SelectTrigger>
                            <SelectContent>
                                {(Object.entries(DATE_TYPE_LABELS) as [DateType, string][]).map(
                                    ([value, label]) => (
                                        <SelectItem key={value} value={value}>
                                            {label}
                                        </SelectItem>
                                    )
                                )}
                            </SelectContent>
                        </Select>
                    </div>

                    <DialogFooter className="pt-4">
                        <Button
                            type="button"
                            variant="ghost"
                            onClick={() => onOpenChange(false)}
                        >
                            Cancelar
                        </Button>
                        <Button type="submit" disabled={loading}>
                            {loading ? "Salvando..." : "Salvar"}
                        </Button>
                    </DialogFooter>
                </form>
            </DialogContent>
        </Dialog>
    );
}
