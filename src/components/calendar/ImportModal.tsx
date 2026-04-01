import { useState, useRef } from "react";
import Papa from "papaparse";
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import {
    Table,
    TableBody,
    TableCell,
    TableHead,
    TableHeader,
    TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Upload, FileSpreadsheet, AlertCircle } from "lucide-react";
import { DATE_TYPE_COLORS, DATE_TYPE_LABELS, DateType } from "@/services/calendarService";

interface ParsedDate {
    title: string;
    description?: string;
    start_date: string;
    end_date?: string;
    type: string;
}

interface ImportModalProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    onImport: (dates: ParsedDate[]) => Promise<void>;
}

export default function ImportModal({ open, onOpenChange, onImport }: ImportModalProps) {
    const [parsedDates, setParsedDates] = useState<ParsedDate[]>([]);
    const [error, setError] = useState<string | null>(null);
    const [loading, setLoading] = useState(false);
    const [fileName, setFileName] = useState<string | null>(null);
    const fileInputRef = useRef<HTMLInputElement>(null);

    const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        if (!file) return;

        setFileName(file.name);
        setError(null);

        Papa.parse(file, {
            header: true,
            skipEmptyLines: true,
            complete: (results) => {
                const data = results.data as Record<string, string>[];

                // Validate required columns
                const requiredCols = ["title", "start_date", "type"];
                const headers = Object.keys(data[0] || {});
                const missingCols = requiredCols.filter(
                    (col) => !headers.includes(col)
                );

                if (missingCols.length > 0) {
                    setError(
                        `Colunas obrigatórias ausentes: ${missingCols.join(", ")}. Colunas esperadas: title, description, start_date, end_date, type`
                    );
                    setParsedDates([]);
                    return;
                }

                // Validate types
                const validTypes = ["prouni", "sisu", "partners", "general"];
                const invalidRows = data.filter(
                    (row) => !validTypes.includes(row.type?.toLowerCase())
                );

                if (invalidRows.length > 0) {
                    setError(
                        `${invalidRows.length} linha(s) com tipo inválido. Tipos aceitos: ${validTypes.join(", ")}`
                    );
                    setParsedDates([]);
                    return;
                }

                const dates: ParsedDate[] = data.map((row) => ({
                    title: row.title,
                    description: row.description || undefined,
                    start_date: row.start_date,
                    end_date: row.end_date || undefined,
                    type: row.type.toLowerCase(),
                }));

                setParsedDates(dates);
            },
            error: (err) => {
                setError(`Erro ao processar CSV: ${err.message}`);
                setParsedDates([]);
            },
        });
    };

    const handleImport = async () => {
        setLoading(true);
        try {
            await onImport(parsedDates);
            setParsedDates([]);
            setFileName(null);
            setError(null);
            onOpenChange(false);
        } catch {
            // Error is handled by the parent
        } finally {
            setLoading(false);
        }
    };

    const handleClose = (isOpen: boolean) => {
        if (!isOpen) {
            setParsedDates([]);
            setFileName(null);
            setError(null);
        }
        onOpenChange(isOpen);
    };

    return (
        <Dialog open={open} onOpenChange={handleClose}>
            <DialogContent className="sm:max-w-2xl max-h-[80vh] overflow-y-auto">
                <DialogHeader>
                    <DialogTitle className="flex items-center gap-2">
                        <FileSpreadsheet className="h-5 w-5" />
                        Importar Datas (CSV)
                    </DialogTitle>
                </DialogHeader>

                <div className="space-y-4 py-4">
                    {/* Upload area */}
                    <div
                        className="border-2 border-dashed rounded-lg p-6 text-center cursor-pointer hover:border-primary/50 transition-colors"
                        onClick={() => fileInputRef.current?.click()}
                    >
                        <input
                            ref={fileInputRef}
                            type="file"
                            accept=".csv"
                            onChange={handleFileChange}
                            className="hidden"
                        />
                        <Upload className="h-8 w-8 mx-auto text-muted-foreground mb-2" />
                        {fileName ? (
                            <p className="text-sm font-medium">{fileName}</p>
                        ) : (
                            <p className="text-sm text-muted-foreground">
                                Clique para selecionar um arquivo CSV
                            </p>
                        )}
                        <p className="text-xs text-muted-foreground mt-1">
                            Colunas: title, description, start_date, end_date, type
                        </p>
                    </div>

                    {/* Error */}
                    {error && (
                        <div className="flex items-start gap-2 p-3 bg-destructive/10 text-destructive rounded-lg text-sm">
                            <AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />
                            {error}
                        </div>
                    )}

                    {/* Preview table */}
                    {parsedDates.length > 0 && (
                        <div>
                            <h4 className="text-sm font-medium mb-2">
                                Preview ({parsedDates.length} datas)
                            </h4>
                            <div className="border rounded-lg max-h-[300px] overflow-y-auto">
                                <Table>
                                    <TableHeader>
                                        <TableRow>
                                            <TableHead>Título</TableHead>
                                            <TableHead>Tipo</TableHead>
                                            <TableHead>Início</TableHead>
                                            <TableHead>Fim</TableHead>
                                        </TableRow>
                                    </TableHeader>
                                    <TableBody>
                                        {parsedDates.map((date, idx) => {
                                            const typeColor =
                                                DATE_TYPE_COLORS[date.type as DateType] || "#999";
                                            const typeLabel =
                                                DATE_TYPE_LABELS[date.type as DateType] || date.type;

                                            return (
                                                <TableRow key={idx}>
                                                    <TableCell className="text-sm max-w-[200px] truncate">
                                                        {date.title}
                                                    </TableCell>
                                                    <TableCell>
                                                        <Badge
                                                            variant="outline"
                                                            style={{
                                                                borderColor: typeColor,
                                                                color: typeColor,
                                                            }}
                                                        >
                                                            {typeLabel}
                                                        </Badge>
                                                    </TableCell>
                                                    <TableCell className="text-xs">
                                                        {date.start_date}
                                                    </TableCell>
                                                    <TableCell className="text-xs text-muted-foreground">
                                                        {date.end_date || "—"}
                                                    </TableCell>
                                                </TableRow>
                                            );
                                        })}
                                    </TableBody>
                                </Table>
                            </div>
                        </div>
                    )}
                </div>

                <DialogFooter>
                    <Button
                        type="button"
                        variant="ghost"
                        onClick={() => handleClose(false)}
                    >
                        Cancelar
                    </Button>
                    <Button
                        onClick={handleImport}
                        disabled={parsedDates.length === 0 || loading}
                    >
                        {loading
                            ? "Importando..."
                            : `Importar ${parsedDates.length} data(s)`}
                    </Button>
                </DialogFooter>
            </DialogContent>
        </Dialog>
    );
}
