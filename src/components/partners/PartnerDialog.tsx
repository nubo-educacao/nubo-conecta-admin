import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
} from "@/components/ui/dialog";
import { PartnerForm } from "./PartnerForm";
import { Partner } from "@/services/partnersService";

interface PartnerDialogProps {
    isOpen: boolean;
    onOpenChange: (open: boolean) => void;
    partner?: Partner;
    onSubmit: (values: any) => Promise<void>;
    onDelete?: () => Promise<void>;
}

export function PartnerDialog({
    isOpen,
    onOpenChange,
    partner,
    onSubmit,
    onDelete,
}: PartnerDialogProps) {
    return (
        <Dialog open={isOpen} onOpenChange={onOpenChange}>
            <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
                <DialogHeader>
                    <DialogTitle>
                        {partner ? "Editar Parceiro" : "Novo Parceiro"}
                    </DialogTitle>
                </DialogHeader>
                <PartnerForm
                    initialData={partner}
                    onSubmit={async (values) => {
                        await onSubmit(values);
                        onOpenChange(false);
                    }}
                    onCancel={() => onOpenChange(false)}
                    onDelete={async () => {
                        if (onDelete) {
                            await onDelete();
                            onOpenChange(false);
                        }
                    }}
                />
            </DialogContent>
        </Dialog>
    );
}
