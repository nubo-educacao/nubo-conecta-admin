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

## Sprint 02 — Ingestão MEC e Parcerias (Diretrizes Arquiteturais)
1. **Pipeline de Importação MEC (`/institutions`)**: A tela das Instituições também se converte no painel de ingestão. Em vez de rodar scripts node na máquina local, o Admin deve prover uma UI (Dropzone CSV) que fará o upload assinado via Supabase Storage invocando uma Edge Function para descarregar o parse via RPCs Postgres (`process_mec_institutions_csv`, etc).
2. **B2B CRUD Desacoplado**: Rotas `/partners` e `/partner-opportunities` gerenciarão Parceiros e suas vagas. É fundamental que oportunidades parceiras tenham o ciclo de review (`pending_review` -> `approved`) validado localmente na visão do Operador.
3. **App CMS (`/app-cms`)**: Criar a interface de curadoria base para pinagem arbitrária de Highlights que forçarão override no modo "Explorar" do aplicativo mobile.
4. **Instruções V1 e Fim do Legado**:
   - A tabela V0 `partners` e as views atreladas estão marcadas como EXTINTAS (**DEPRECATED**) na Sprint 3.8.
   - Qualquer nova modelagem deve focar inteiramente na separação dos schemas `institutions` (is_partner=true), `partner_institutions` (metadata, visual assets via bucket: partners) e `partner_opportunities` (vagas daquele parceiro).
   - O SSR do Next deve usar seleções limitadas de colunas para contornar falhas silenciosas envolvendo fields desatualizados.
