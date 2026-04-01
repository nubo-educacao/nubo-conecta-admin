import { useState } from "react";
import { Calendar, ChevronDown, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  DropdownMenuSeparator,
  DropdownMenuLabel,
} from "@/components/ui/dropdown-menu";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { Calendar as CalendarComponent } from "@/components/ui/calendar";
import { cn } from "@/lib/utils";
import { format } from "date-fns";
import { ptBR } from "date-fns/locale";

export type DateRangeValue = "today" | "7d" | "14d" | "30d" | "90d" | "year" | "custom";

export interface DateRangeOption {
  label: string;
  value: DateRangeValue;
}

const dateRanges: DateRangeOption[] = [
  { label: "Hoje", value: "today" },
  { label: "Últimos 7 dias", value: "7d" },
  { label: "Últimos 14 dias", value: "14d" },
  { label: "Últimos 30 dias", value: "30d" },
  { label: "Últimos 90 dias", value: "90d" },
  { label: "Este ano", value: "year" },
];

interface DateRangeFilterProps {
  selectedRange?: DateRangeValue;
  onDateChange?: (range: DateRangeValue) => void;
  onCustomDateChange?: (date: Date | undefined) => void;
  onRefresh?: () => void;
  isRefreshing?: boolean;
}

export function DateRangeFilter({ 
  selectedRange = "7d",
  onDateChange, 
  onCustomDateChange,
  onRefresh,
  isRefreshing = false,
}: DateRangeFilterProps) {
  const [customDate, setCustomDate] = useState<Date | undefined>(undefined);
  const [showCustom, setShowCustom] = useState(false);

  const currentRange = dateRanges.find(r => r.value === selectedRange) || dateRanges[1];

  const handleRangeSelect = (range: DateRangeOption) => {
    setShowCustom(false);
    setCustomDate(undefined);
    onDateChange?.(range.value);
  };

  const handleCustomDateSelect = (date: Date | undefined) => {
    setCustomDate(date);
    if (date) {
      setShowCustom(true);
      onCustomDateChange?.(date);
      onDateChange?.("custom");
    }
  };

  return (
    <div className="flex items-center gap-2">
      {/* Date Range Dropdown */}
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="outline" className="gap-2 font-medium">
            <Calendar className="h-4 w-4" />
            <span className="hidden sm:inline">
              {showCustom && customDate 
                ? format(customDate, "dd/MM/yyyy", { locale: ptBR })
                : currentRange.label
              }
            </span>
            <span className="sm:hidden">
              {showCustom && customDate 
                ? format(customDate, "dd/MM", { locale: ptBR })
                : currentRange.value === "today" ? "Hoje" : currentRange.value
              }
            </span>
            <ChevronDown className="h-4 w-4 opacity-50" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-56">
          <DropdownMenuLabel>Período predefinido</DropdownMenuLabel>
          {dateRanges.map((range) => (
            <DropdownMenuItem
              key={range.value}
              onClick={() => handleRangeSelect(range)}
              className={cn(
                "cursor-pointer",
                selectedRange === range.value && !showCustom && "bg-accent"
              )}
            >
              {range.label}
            </DropdownMenuItem>
          ))}
          <DropdownMenuSeparator />
          <DropdownMenuLabel>Data específica</DropdownMenuLabel>
          <div className="p-2">
            <Popover>
              <PopoverTrigger asChild>
                <Button variant="outline" size="sm" className="w-full justify-start">
                  <Calendar className="h-4 w-4 mr-2" />
                  {customDate 
                    ? format(customDate, "dd/MM/yyyy", { locale: ptBR })
                    : "Escolher data"
                  }
                </Button>
              </PopoverTrigger>
              <PopoverContent className="w-auto p-0" align="start">
                <CalendarComponent
                  mode="single"
                  selected={customDate}
                  onSelect={handleCustomDateSelect}
                  initialFocus
                  className="p-3 pointer-events-auto"
                  locale={ptBR}
                />
              </PopoverContent>
            </Popover>
          </div>
        </DropdownMenuContent>
      </DropdownMenu>

      {/* Refresh Button */}
      <Button 
        variant="outline" 
        size="icon" 
        className="shrink-0"
        onClick={onRefresh}
        disabled={isRefreshing}
      >
        <RefreshCw className={cn("h-4 w-4", isRefreshing && "animate-spin")} />
      </Button>
    </div>
  );
}