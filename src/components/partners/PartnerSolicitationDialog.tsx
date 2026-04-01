import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { PartnerSolicitation } from "@/services/partnerSolicitationsService";

interface PartnerSolicitationDialogProps {
    isOpen: boolean;
    onOpenChange: (open: boolean) => void;
    solicitation: PartnerSolicitation | null;
}

export function PartnerSolicitationDialog({
    isOpen,
    onOpenChange,
    solicitation,
}: PartnerSolicitationDialogProps) {
    if (!solicitation) return null;

    return (
        <Dialog open={isOpen} onOpenChange={onOpenChange}>
            <DialogContent className="max-w-lg">
                <DialogHeader>
                    <DialogTitle>Detalhes da Solicitação</DialogTitle>
                </DialogHeader>
                <div className="space-y-4">
                    <div className="space-y-2">
                        <Label>Como você conheceu a Nubo?</Label>
                        <Textarea
                            readOnly
                            value={solicitation.how_did_you_know || "N/A"}
                            className="resize-none bg-muted"
                        />
                    </div>
                    <div className="space-y-2">
                        <Label>Qual o objetivo da parceria?</Label>
                        <Textarea
                            readOnly
                            value={solicitation.goals || "N/A"}
                            className="min-h-[100px] resize-none bg-muted"
                        />
                    </div>
                </div>
            </DialogContent>
        </Dialog>
    );
}
