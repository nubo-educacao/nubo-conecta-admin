import type { DateRangeValue } from '@/components/analytics/DateRangeFilter';
import type { DateRange } from './analytics-queries';
export function commandCenterDateRange(range: DateRangeValue, now: Date, customDate?: Date): DateRange {
  const from = new Date(range === 'custom' && customDate ? customDate : now);
  from.setHours(0, 0, 0, 0);
  const to = new Date(from);
  to.setDate(to.getDate() + 1);
  if (range === 'year') from.setMonth(0, 1);
  else if (range !== 'today' && range !== 'custom') from.setDate(from.getDate() - Number(range.replace('d', '')) + 1);
  return { from, to };
}
