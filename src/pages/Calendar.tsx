import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Plus, Upload, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { toast } from "sonner";
import CalendarView from "@/components/calendar/CalendarView";
import DatesList from "@/components/calendar/DatesList";
import DatesTable from "@/components/calendar/DatesTable";
import DateModal from "@/components/calendar/DateModal";
import ImportModal from "@/components/calendar/ImportModal";
import {
    getImportantDates,
    createImportantDate,
    updateImportantDate,
    deleteImportantDate,
    bulkImportDates,
    ImportantDate,
} from "@/services/calendarService";
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

export default function Calendar() {
    const queryClient = useQueryClient();
    const [selectedMonth, setSelectedMonth] = useState(new Date());
    const [selectedDay, setSelectedDay] = useState<Date | undefined>();
    const [isDateModalOpen, setIsDateModalOpen] = useState(false);
    const [isImportModalOpen, setIsImportModalOpen] = useState(false);
    const [selectedDate, setSelectedDate] = useState<ImportantDate | undefined>();
    const [deleteTarget, setDeleteTarget] = useState<ImportantDate | null>(null);

    // Query
    const { data: dates = [], isLoading } = useQuery({
        queryKey: ["important-dates"],
        queryFn: getImportantDates,
    });

    // Mutations
    const createMutation = useMutation({
        mutationFn: createImportantDate,
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["important-dates"] });
            toast.success("Data criada com sucesso!");
        },
        onError: (err: any) => toast.error(err.message || "Erro ao criar data."),
    });

    const updateMutation = useMutation({
        mutationFn: ({ id, data }: { id: string; data: any }) =>
            updateImportantDate(id, data),
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["important-dates"] });
            toast.success("Data atualizada com sucesso!");
        },
        onError: (err: any) => toast.error(err.message || "Erro ao atualizar data."),
    });

    const deleteMutation = useMutation({
        mutationFn: deleteImportantDate,
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["important-dates"] });
            toast.success("Data removida com sucesso!");
        },
        onError: (err: any) => toast.error(err.message || "Erro ao remover data."),
    });

    const importMutation = useMutation({
        mutationFn: bulkImportDates,
        onSuccess: (count) => {
            queryClient.invalidateQueries({ queryKey: ["important-dates"] });
            toast.success(`${count} data(s) importada(s) com sucesso!`);
        },
        onError: (err: any) => toast.error(err.message || "Erro ao importar datas."),
    });

    // Handlers
    const handleAddDate = () => {
        setSelectedDate(undefined);
        setIsDateModalOpen(true);
    };

    const handleEditDate = (date: ImportantDate) => {
        setSelectedDate(date);
        setIsDateModalOpen(true);
    };

    const handleDeleteDate = (date: ImportantDate) => {
        setDeleteTarget(date);
    };

    const confirmDelete = async () => {
        if (deleteTarget) {
            await deleteMutation.mutateAsync(deleteTarget.id);
            setDeleteTarget(null);
        }
    };

    const handleSubmitDate = async (data: {
        title: string;
        description?: string;
        start_date: string;
        end_date?: string;
        type: string;
    }) => {
        if (selectedDate) {
            await updateMutation.mutateAsync({ id: selectedDate.id, data });
        } else {
            await createMutation.mutateAsync(data);
        }
    };

    const handleImport = async (
        dates: Array<{
            title: string;
            description?: string;
            start_date: string;
            end_date?: string;
            type: string;
        }>
    ) => {
        await importMutation.mutateAsync(dates);
    };

    if (isLoading) {
        return (
            <div className="flex h-[400px] items-center justify-center">
                <Loader2 className="h-8 w-8 animate-spin text-primary" />
            </div>
        );
    }

    return (
        <div className="container mx-auto space-y-8 p-6">
            {/* Header */}
            <div className="flex items-center justify-between">
                <div>
                    <h1 className="text-3xl font-bold tracking-tight">Calendário</h1>
                    <p className="text-muted-foreground">
                        Gerencie as datas importantes do Nubo.
                    </p>
                </div>
                <div className="flex items-center gap-2">
                    <Button
                        variant="outline"
                        className="gap-2"
                        onClick={() => setIsImportModalOpen(true)}
                    >
                        <Upload className="h-4 w-4" />
                        Importar
                    </Button>
                    <Button className="gap-2" onClick={handleAddDate}>
                        <Plus className="h-4 w-4" />
                        Adicionar data
                    </Button>
                </div>
            </div>

            {/* Calendar + Dates List */}
            <div className="flex gap-6 items-start">
                <div className="shrink-0">
                    <CalendarView
                        dates={dates}
                        selectedMonth={selectedMonth}
                        onMonthChange={setSelectedMonth}
                        selectedDay={selectedDay}
                        onDaySelect={setSelectedDay}
                    />
                </div>
                <DatesList dates={dates} selectedMonth={selectedMonth} />
            </div>

            {/* All Dates Table */}
            <div className="space-y-4">
                <h2 className="text-xl font-semibold">Todas as datas</h2>
                <DatesTable
                    dates={dates}
                    onEdit={handleEditDate}
                    onDelete={handleDeleteDate}
                />
            </div>

            {/* Modals */}
            <DateModal
                open={isDateModalOpen}
                onOpenChange={setIsDateModalOpen}
                date={selectedDate}
                onSubmit={handleSubmitDate}
            />

            <ImportModal
                open={isImportModalOpen}
                onOpenChange={setIsImportModalOpen}
                onImport={handleImport}
            />

            {/* Delete Confirmation */}
            <AlertDialog
                open={!!deleteTarget}
                onOpenChange={(open) => !open && setDeleteTarget(null)}
            >
                <AlertDialogContent>
                    <AlertDialogHeader>
                        <AlertDialogTitle>Confirmar exclusão</AlertDialogTitle>
                        <AlertDialogDescription>
                            Tem certeza que deseja excluir "{deleteTarget?.title}"? Esta
                            ação não pode ser desfeita.
                        </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                        <AlertDialogCancel>Cancelar</AlertDialogCancel>
                        <AlertDialogAction
                            onClick={confirmDelete}
                            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                        >
                            Excluir
                        </AlertDialogAction>
                    </AlertDialogFooter>
                </AlertDialogContent>
            </AlertDialog>
        </div>
    );
}
