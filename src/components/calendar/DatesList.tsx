import { ImportantDate, DATE_TYPE_COLORS, DATE_TYPE_LABELS, DateType } from "@/services/calendarService";
import { Badge } from "@/components/ui/badge";
import { format, isSameMonth } from "date-fns";
import { ptBR } from "date-fns/locale";
import { CalendarDays } from "lucide-react";

interface DatesListProps {
    dates: ImportantDate[];
    selectedMonth: Date;
}

export default function DatesList({ dates, selectedMonth }: DatesListProps) {
    // Filter dates that fall within the selected month
    const monthDates = dates.filter((d) => {
        const start = new Date(d.start_date);
        const end = d.end_date ? new Date(d.end_date) : start;
        return isSameMonth(start, selectedMonth) || isSameMonth(end, selectedMonth);
    });

    const formatDateRange = (startStr: string, endStr?: string | null) => {
        const start = new Date(startStr);
        const startFormatted = format(start, "dd MMM", { locale: ptBR });

        if (endStr) {
            const end = new Date(endStr);
            const endFormatted = format(end, "dd MMM", { locale: ptBR });
            return `${startFormatted} — ${endFormatted}`;
        }

        return startFormatted;
    };

    const monthLabel = format(selectedMonth, "MMMM yyyy", { locale: ptBR });

    return (
        <div className="bg-card border rounded-lg p-4 shadow-sm flex-1">
            <h3 className="text-lg font-semibold mb-4 capitalize flex items-center gap-2">
                <CalendarDays className="h-5 w-5 text-muted-foreground" />
                {monthLabel}
            </h3>

            {monthDates.length === 0 ? (
                <p className="text-sm text-muted-foreground italic py-4">
                    Nenhuma data neste mês.
                </p>
            ) : (
                <div className="space-y-3">
                    {monthDates.map((date) => {
                        const typeColor = DATE_TYPE_COLORS[date.type as DateType] || "#999";
                        const typeLabel = DATE_TYPE_LABELS[date.type as DateType] || date.type;

                        return (
                            <div
                                key={date.id}
                                className="flex items-start gap-3 p-3 rounded-lg bg-muted/50 hover:bg-muted transition-colors"
                            >
                                <div
                                    className="w-1 rounded-full self-stretch shrink-0"
                                    style={{ backgroundColor: typeColor }}
                                />
                                <div className="flex-1 min-w-0">
                                    <div className="flex items-center gap-2 mb-1">
                                        <span className="font-medium text-sm truncate">
                                            {date.title}
                                        </span>
                                        <Badge
                                            variant="outline"
                                            className="shrink-0 text-xs"
                                            style={{
                                                borderColor: typeColor,
                                                color: typeColor,
                                            }}
                                        >
                                            {typeLabel}
                                        </Badge>
                                    </div>
                                    <p className="text-xs text-muted-foreground">
                                        {formatDateRange(date.start_date, date.end_date)}
                                    </p>
                                    {date.description && (
                                        <p className="text-xs text-muted-foreground mt-1 line-clamp-2">
                                            {date.description}
                                        </p>
                                    )}
                                </div>
                            </div>
                        );
                    })}
                </div>
            )}
        </div>
    );
}
