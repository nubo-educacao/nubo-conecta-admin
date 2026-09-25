# Transferência do projeto Supabase `nubo-hub` (Dev) para a organização `nubo-dev`

**Card:** Migrar banco nubo-hub para outra organização (`43e52588`) · **Execução Snaps:** `e614a042` · **Data:** 2026-09-25

## Escopo

Mover o projeto **nubo-hub** (ref `yfgciamhzjvarwgzosto`, DEV/staging, região São Paulo) da organização
**nubo-educacao** (plano **Pro**) para a nova organização **nubo-dev** (plano **Free**).

Não é migração de dados: a migração Dev→Prod terminou em 2026-06-14 (ADR-0021, PR #13).
Prod (`aifzkybxhmefbirujvdg`, "nubo-hub-prod") continua em nubo-educacao e não é afetado.

## O que muda e o que não muda

**Não muda:** project ref, URL `https://yfgciamhzjvarwgzosto.supabase.co`, chaves anon/service_role,
host e pooler de conexão, dados, Auth, Storage, pg_cron. Transferência entre organizações não troca região.
Logo, nenhum `.env`, secret de CI, Vercel ou Cloud Run precisa ser alterado.

**Muda (Pro → Free):**
- ~1–2 min de downtime durante a transferência.
- Perda dos recursos do Pro: backups diários, sem pausa por inatividade, limites maiores.
- No Free, o projeto **pausa após 7 dias sem atividade** — restaurar pelo dashboard quando acontecer.
- O Supabase valida o limite de 2 projetos Free ativos na transferência.
- Billing: nubo-educacao paga o uso até a transferência; nubo-dev (Free) depois.

## Estado auditado antes da transferência (2026-09-25)

| Item | Valor |
|---|---|
| Tamanho do banco | 396 MB |
| `auth.users` | 95 |
| Storage | 4 buckets · 46 objetos |
| pg_cron | 1 job ativo: `check-program-deadlines` (08:00 diário) |
| Realtime | 0 tabelas publicadas |
| Integração GitHub | nenhuma (verificado em nubo-educacao → Integrations) |
| Extensões | pg_cron, pg_net, vector, pg_trgm, unaccent, cube, earthdistance, pgcrypto, uuid-ossp, supabase_vault, pg_stat_statements |

## Pré-requisitos

- [ ] Quem executa é **Owner** de nubo-educacao e ao menos **Member** de nubo-dev.
- [x] Sem integração GitHub ativa.
- [ ] Sem log drains configurados.
- [ ] Sem add-ons que o Free não suporte (compute, PITR, IPv4, custom domain) — remover ou aceitar a perda.

## Passos

1. Criar a organização **nubo-dev** (plano Free) e convidar os membros necessários.
2. Conferir os pré-requisitos acima no projeto nubo-hub.
3. Backup do Dev (`npx supabase db dump` ou backup do dashboard) — o Free não tem backup diário.
4. nubo-hub → Project Settings → General → **Transfer project** → nubo-dev.
5. Smoke test: `auth.users` = 95, `storage.objects` = 46, `cron.job` ativo; app, admin e Cloudinha
   em ambiente dev autenticam normalmente.
6. Atualizar `Database Migration Workflow` (Snaps) com a nova organização.

**Rollback:** transferir o projeto de volta para nubo-educacao.
