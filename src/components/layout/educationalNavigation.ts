export const EDUCATIONAL_NAV_ITEMS = [
  { to: "/educational/programs-import", label: "Programas & Importação" },
  { to: "/educational/institutions-campus", label: "Instituições & Campus" },
  { to: "/educational/opportunities-courses", label: "Oportunidades & Cursos" },
];

// Dashboard MEC abre o grupo "Dados Educacionais" na Sidebar (NUB-RD-94). Fica fora
// de EDUCATIONAL_NAV_ITEMS, que segue sendo as três entradas canônicas da ADR-0026.
export const MEC_DASHBOARD_NAV_ITEM = { to: "/educational/mec-dashboard", label: "Dashboard MEC" };
