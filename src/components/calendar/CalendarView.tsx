import { DayPicker } from "react-day-picker";
import "react-day-picker/dist/style.css";
import { ImportantDate, DATE_TYPE_COLORS, DateType } from "@/services/calendarService";
import { ptBR } from "date-fns/locale";

interface CalendarViewProps {
    dates: ImportantDate[];
    selectedMonth: Date;
    onMonthChange: (month: Date) => void;
    selectedDay: Date | undefined;
    onDaySelect: (day: Date | undefined) => void;
}

export default function CalendarView({
    dates,
    selectedMonth,
    onMonthChange,
    selectedDay,
    onDaySelect,
}: CalendarViewProps) {
    // Build a map of day -> types for dot rendering
    const dayTypeMap = new Map<string, Set<DateType>>();

    dates.forEach((d) => {
        const start = new Date(d.start_date);
        const end = d.end_date ? new Date(d.end_date) : start;
        const current = new Date(start);
        current.setHours(0, 0, 0, 0);
        const endNorm = new Date(end);
        endNorm.setHours(0, 0, 0, 0);

        while (current <= endNorm) {
            const key = current.toISOString().split("T")[0];
            if (!dayTypeMap.has(key)) {
                dayTypeMap.set(key, new Set());
            }
            dayTypeMap.get(key)!.add(d.type as DateType);
            current.setDate(current.getDate() + 1);
        }
    });

    return (
        <div className="bg-card border rounded-lg p-4 shadow-sm">
            <style>{`
                .rdp {
                    --rdp-cell-size: 40px;
                    --rdp-accent-color: #024F86;
                    margin: 0;
                }
                .rdp-day_selected:not([disabled]) {
                    background-color: var(--rdp-accent-color);
                    color: white;
                }
                .rdp-day_selected:hover:not([disabled]) {
                    background-color: #013a63;
                }
                .calendar-day-wrapper {
                    position: relative;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                }
                .calendar-dots {
                    display: flex;
                    gap: 2px;
                    margin-top: 1px;
                    position: absolute;
                    bottom: -2px;
                }
                .calendar-dot {
                    width: 5px;
                    height: 5px;
                    border-radius: 50%;
                }
            `}</style>
            <DayPicker
                mode="single"
                locale={ptBR}
                selected={selectedDay}
                onSelect={onDaySelect}
                month={selectedMonth}
                onMonthChange={onMonthChange}
                showOutsideDays
                components={{
                    DayContent: ({ date }) => {
                        const key = date.toISOString().split("T")[0];
                        const types = dayTypeMap.get(key);
                        return (
                            <div className="calendar-day-wrapper">
                                <span>{date.getDate()}</span>
                                {types && types.size > 0 && (
                                    <div className="calendar-dots">
                                        {Array.from(types).map((type) => (
                                            <div
                                                key={type}
                                                className="calendar-dot"
                                                style={{
                                                    backgroundColor:
                                                        DATE_TYPE_COLORS[type] || "#999",
                                                }}
                                            />
                                        ))}
                                    </div>
                                )}
                            </div>
                        );
                    },
                }}
            />
        </div>
    );
}
