import type { DateRange } from './analytics-queries';

export function analyticsCsv(headers: string[], rows: (string | number)[][]) {
  // Neutralize spreadsheet formulas as well as escaping quotes and separators.
  const cell = (value: string | number) => {
    const text = String(value ?? '');
    const safe = /^[\s]*[=+@-]/.test(text) ? "'" + text : text;
    return '"' + safe.replace(/"/g, '""') + '"';
  };
  return '\uFEFF' + [headers, ...rows].map(row => row.map(cell).join(';')).join('\n');
}

export function downloadAnalyticsCsv(headers: string[], rows: (string | number)[][], name: string, range?: DateRange) {
  const content = analyticsCsv(headers, rows);
  const url = URL.createObjectURL(new Blob([content], { type: 'text/csv;charset=utf-8;' }));
  const link = document.createElement('a');
  link.href = url;
  const period = range?.from && range?.to ? range.from.toISOString().slice(0, 10) + '_ate_' +
    new Date(range.to.getTime() - 1).toISOString().slice(0, 10) : 'sem-filtro';
  link.download = name + '_' + period + '.csv';
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}
