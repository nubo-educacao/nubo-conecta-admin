import { LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { InfoTooltip } from "@/components/analytics/InfoTooltip";

interface StatCardProps {
  title: string;
  value: string | number;
  change?: number;
  changeLabel?: string;
  icon: LucideIcon;
  variant?: "default" | "success" | "warning" | "error";
  tooltip?: string;
}

const variantStyles = {
  default: "before:bg-gradient-to-r before:from-primary before:to-chart-2",
  success: "before:bg-gradient-to-r before:from-success before:to-emerald-400",
  warning: "before:bg-gradient-to-r before:from-warning before:to-amber-400",
  error: "before:bg-gradient-to-r before:from-destructive before:to-rose-400",
};

const iconVariantStyles = {
  default: "bg-primary/10 text-primary",
  success: "bg-success/10 text-success",
  warning: "bg-warning/10 text-warning",
  error: "bg-destructive/10 text-destructive",
};

export function StatCard({
  title,
  value,
  change,
  changeLabel,
  icon: Icon,
  variant = "default",
  tooltip,
}: StatCardProps) {
  const isPositive = change && change > 0;
  const isNegative = change && change < 0;

  return (
    <div className={cn("stat-card", variantStyles[variant])}>
      <div className="flex items-start justify-between">
        <div className="space-y-1">
          <div className="flex items-center gap-1.5">
            <p className="text-sm font-medium text-muted-foreground">{title}</p>
            {tooltip && <InfoTooltip label={title}>{tooltip}</InfoTooltip>}
          </div>
          <p className="text-3xl font-bold font-display tracking-tight">
            {value}
          </p>
        </div>
        <div className={cn("rounded-xl p-3", iconVariantStyles[variant])}>
          <Icon className="h-5 w-5" />
        </div>
      </div>
      
      {change !== undefined && (
        <div className="mt-4 flex items-center gap-2">
          <span
            className={cn(
              "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
              isPositive && "bg-success/10 text-success",
              isNegative && "bg-destructive/10 text-destructive",
              !isPositive && !isNegative && "bg-muted text-muted-foreground"
            )}
          >
            {isPositive && "+"}
            {change}%
          </span>
          <span className="text-xs text-muted-foreground">
            {changeLabel || "vs período anterior"}
          </span>
        </div>
      )}
    </div>
  );
}
