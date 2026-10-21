/** Dates on the B2B/MEC dashboards are always shown in Brasília time, whatever the browser's zone. */
export function formatBrt(value: Date | string): string {
  return new Date(value)
    .toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" })
    .replace(",", "");
}
