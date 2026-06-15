# Scripts de Migração Dev → Prod

## Ordem de Execução

```
1. pre-push-prod.sql       ← Executar no SQL Editor do Supabase PROD antes do db push
2. npx supabase db push    ← Card 1: aplicar migrations pendentes
3. migrate-dev-to-prod.ts  ← Card 2: migrar dados
4. validate-prod.sql       ← Card 3: validar retenção
5. [Deploy Vercel + DNS]   ← Card 4: manual
6. post-migration-cleanup.sql ← Card 5: limpeza pós-deploy
```

## Como Executar o Script de Migração

```bash
cd nubo-conecta-admin

# Configurar variáveis de ambiente
export DEV_SUPABASE_URL="https://<dev-ref>.supabase.co"
export DEV_SUPABASE_SERVICE_KEY="eyJ..."
export PROD_SUPABASE_URL="https://<prod-ref>.supabase.co"
export PROD_SUPABASE_SERVICE_KEY="eyJ..."

# Executar
npx tsx scripts/migrate-dev-to-prod.ts
```

## O que o script FAZ

- **TRUNCATE** das tabelas educacionais (leaf-first, respeita FK)
- **INSERT paginado** (500 reg/batch) de todas as tabelas de dev para prod
- **Mapeia os 6 `partners` legados** para `partner_institutions` + `partner_opportunities`
- **REFRESH** da materialized view `v_unified_opportunities`
- **Validação final** com contagens esperadas

## O que o script NÃO FAZ (preservado em prod)

- `partners` — mantidos (6 registros)
- `partner_forms` — mantidos (233 registros)
- `partner_steps` — mantidos (26 registros)
- `student_applications` — mantidos (430 registros)
- `knowledge_documents` — mantidos (5 registros)
- `partners_click`, `partners_users`, `partner_solicitations` — mantidos
- `auth.users`, `user_profiles`, `chat_messages` e demais dados de usuário — intocados

## Tabelas zeradas intencionalmente

- `user_favorites` — IDs de cursos mudam entre dev e prod (remap inviável)
- `external_redirect_clicks` — dados transacionais legados
- `passport_applications` — 0 registros, sem impacto
