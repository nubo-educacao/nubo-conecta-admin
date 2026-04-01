# Project Context: Nubo Conecta Admin
> Este arquivo é o cérebro local do backoffice Admin.
> Tanto Antigravity (IDE) quanto Claude (CLI) devem ler este arquivo ao atuar nesta pasta.

## Source of Truth (PRD)
@import ../nubo-ops/docs/prd_novo_admin.md

## Technical Stack
- **Framework**: React 18
- **Build Tool**: Vite 6
- **Styling**: Tailwind CSS 4.0 + shadcn/ui
- **State/Fetching**: TanStack Query
- **Routing**: React Router DOM

## Sprint 01 — Orientação Arquitetural e Bugs Críticos
1. **Migrations Timestamp (Supabase)**: Nova baseline gerenciada na pasta `supabase/migrations/` rodando o CLI `npx supabase init`. A criação segue restritamente o formato numérico seqüencial longo (`YYYYMMDDHHMMSS_name.sql`).
2. **Scaffolding Refactoring**: Iniciar copiando a casca do projeto prévio `/nubo-hub-admin/`. Preservar dependências (`shadcn/ui`, `tanstack query`, `AuthContext`) e estirpar apêndices obsoletos do domínio "passaporte".
3. **Bug Crítico (Error 404 Request Not Found na SPA)**: Em produção, Vercel/Netlify estão falhando no fallback local. Instrução Primária do Sprint: Ajustar as configurações (`vite.config.ts`, `vercel.json` ou `_redirects` respectivo) para servir regra Rewrite catch-all devolvendo `index.html` em qualquer rota `/*`, garantindo que o ciclo react-router recubra os refreshes de página (`F5`).
