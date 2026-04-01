import { useState } from "react";
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
import { toast } from "sonner";
import { Copy, Check } from "lucide-react";

interface TrackableLinkModalProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    influencerCode: string | null;
}

export default function TrackableLinkModal({
    open,
    onOpenChange,
    influencerCode,
}: TrackableLinkModalProps) {
    const [copied, setCopied] = useState(false);
    const link = `https://conecta.nuboeducacao.com.br/?ref=${influencerCode || ""}`;

    const handleCopy = () => {
        navigator.clipboard.writeText(link);
        setCopied(true);
        toast.success("Link copiado para a área de transferência!");
        setTimeout(() => setCopied(false), 2000);
    };

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="sm:max-w-[425px]">
                <DialogHeader>
                    <DialogTitle>Link Trackeável</DialogTitle>
                </DialogHeader>
                <div className="space-y-4 py-4">
                    <div className="space-y-2">
                        <Label htmlFor="link">Link de Afiliado</Label>
                        <div className="flex gap-2">
                            <Input
                                id="link"
                                value={link}
                                readOnly
                                className="bg-muted"
                            />
                            <Button size="icon" onClick={handleCopy}>
                                {copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
                            </Button>
                        </div>
                    </div>
                </div>
                <DialogFooter>
                    <Button variant="secondary" onClick={() => onOpenChange(false)} className="w-full">
                        Fechar
                    </Button>
                </DialogFooter>
            </DialogContent>
        </Dialog>
    );
}
