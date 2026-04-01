import { Cloud, Settings, Clock } from "lucide-react";
import { Button } from "@/components/ui/button";
import { DateRangeFilter, DateRangeValue } from "./DateRangeFilter";
import { format } from "date-fns";
import { ptBR } from "date-fns/locale";
import SegmentedExportButton from "./SegmentedExportButton";

interface DashboardHeaderProps {
  selectedRange: DateRangeValue;
  onRangeChange: (range: DateRangeValue) => void;
  onRefresh: () => void;
  isRefreshing: boolean;
  lastUpdate: Date;
}

export function DashboardHeader({
  selectedRange,
  onRangeChange,
  onRefresh,
  isRefreshing,
  lastUpdate,
}: DashboardHeaderProps) {
  const formatLastUpdate = () => {
    return format(lastUpdate, "dd/MM/yyyy 'às' HH:mm:ss", { locale: ptBR });
  };

  return (
    <header className="sticky top-0 z-40 backdrop-blur-md bg-background/80 border-b border-border">
      <div className="container py-3 sm:py-4">
        <div className="flex items-center justify-between gap-2 sm:gap-4">
          {/* Logo and Title */}
          <div className="flex items-center gap-2 sm:gap-3 min-w-0">
            <div className="flex h-8 w-8 sm:h-10 sm:w-10 items-center justify-center rounded-xl bg-gradient-to-br from-primary to-chart-2 text-primary-foreground shadow-glow shrink-0">
              <Cloud className="h-4 w-4 sm:h-5 sm:w-5" />
            </div>
            <div className="min-w-0">
              <h1 className="text-lg sm:text-xl font-bold font-display tracking-tight truncate">
                Cloudinha Analytics
              </h1>
              <p className="text-xs text-muted-foreground/70 flex items-center gap-1 hidden sm:flex">
                <Clock className="h-3 w-3" />
                Atualizado: {formatLastUpdate()}
              </p>
            </div>
          </div>

          {/* Desktop Actions */}
          <div className="hidden md:flex items-center gap-2">
            <SegmentedExportButton />
            <DateRangeFilter
              selectedRange={selectedRange}
              onDateChange={onRangeChange}
              onRefresh={onRefresh}
              isRefreshing={isRefreshing}
            />
            <Button variant="outline" size="icon" className="shrink-0">
              <Settings className="h-4 w-4" />
            </Button>
          </div>

          {/* Mobile Actions */}
          <div className="flex md:hidden items-center gap-2">
            <DateRangeFilter
              selectedRange={selectedRange}
              onDateChange={onRangeChange}
              onRefresh={onRefresh}
              isRefreshing={isRefreshing}
            />
          </div>
        </div>

        {/* Mobile last update */}
        <p className="text-xs text-muted-foreground/70 flex items-center gap-1 mt-2 sm:hidden">
          <Clock className="h-3 w-3" />
          Atualizado: {formatLastUpdate()}
        </p>
      </div>
    </header>
  );
}