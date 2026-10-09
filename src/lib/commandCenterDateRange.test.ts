import { describe, it, expect } from 'vitest';
import { commandCenterDateRange } from './commandCenterDateRange';
describe('Command Center period', () => {
  const now = new Date(2026, 9, 9, 16, 0);
  it('uses a seven calendar-day range with an exclusive end', () => {
    expect(commandCenterDateRange('7d', now)).toEqual({ from: new Date(2026, 9, 3), to: new Date(2026, 9, 10) });
  });
  it('supports today, year and a custom single day', () => {
    expect(commandCenterDateRange('today', now).from).toEqual(new Date(2026, 9, 9));
    expect(commandCenterDateRange('year', now).from).toEqual(new Date(2026, 0, 1));
    expect(commandCenterDateRange('custom', now, new Date(2026, 8, 2))).toEqual({ from: new Date(2026, 8, 2), to: new Date(2026, 8, 3) });
  });
});
