-- pre-push-prod.sql
-- ==================
-- Executar no SQL Editor do Supabase PROD *antes* de rodar `npx supabase db push`
-- Resolve o conflito BUG-2: tabelas legadas com nomes que colidem com migrations pendentes.
-- Plano: ca81e337 | Passo 1.0

-- 1. Verificar estado atual (execute separadamente para inspecionar)
SELECT 'institutions_info_emec' as tabela, count(*) FROM institutions_info_emec
UNION ALL SELECT 'institutionsinfoemec', count(*) FROM institutionsinfoemec
UNION ALL SELECT 'institutions_info_sisu', count(*) FROM institutions_info_sisu
UNION ALL SELECT 'institutionsinfosisu', count(*) FROM institutionsinfosisu;

-- 2. Dropar tabelas legadas que conflitam com renames das migrations
-- (as versões novas já existem em prod com dados ou serão criadas pelo push)
DROP TABLE IF EXISTS institutionsinfoemec CASCADE;
DROP TABLE IF EXISTS institutionsinfosisu CASCADE;

-- 3. Verificar opportunitiessisuvacancies vs opportunities_sisu_vacancies
SELECT 'opportunities_sisu_vacancies' as tabela, count(*) FROM opportunities_sisu_vacancies
UNION ALL SELECT 'opportunitiessisuvacancies', count(*) FROM opportunitiessisuvacancies;

-- Se opportunitiessisuvacancies ainda tem dados que não estão em opportunities_sisu_vacancies,
-- avaliar se precisam ser migrados antes de dropar.
DROP TABLE IF EXISTS opportunitiessisuvacancies CASCADE;
