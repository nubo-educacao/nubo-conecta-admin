-- post-migration-cleanup.sql
-- ============================
-- Executar no SQL Editor do Supabase PROD *após* validar o Card 4 (Deploy + smoke tests OK).
-- Remove tabelas e views legadas que ficaram como órfãs após o schema push.
-- Plano: ca81e337 | Card 5

-- Views legadas do admin (não existem em dev)
DROP VIEW IF EXISTS vw_admin_funnel_chart CASCADE;
DROP VIEW IF EXISTS vw_admin_furthest_passport_phases CASCADE;
DROP VIEW IF EXISTS vw_admin_passport_phases CASCADE;
DROP VIEW IF EXISTS vw_admin_user_funnel CASCADE;
DROP VIEW IF EXISTS vw_partner_application_completion_buckets CASCADE;
DROP VIEW IF EXISTS vw_partner_application_details CASCADE;
DROP VIEW IF EXISTS vw_partner_funnel CASCADE;
DROP VIEW IF EXISTS reversed_student_applications CASCADE;

-- Raw tables históricas com ano (substituídas pelas genéricas de dev)
DROP TABLE IF EXISTS rawprouni2025 CASCADE;
DROP TABLE IF EXISTS rawprouniocuppied2025 CASCADE;
DROP TABLE IF EXISTS rawprounivacancies2025 CASCADE;
DROP TABLE IF EXISTS rawsisu2025 CASCADE;
DROP TABLE IF EXISTS rawsisuapprovals2026 CASCADE;
DROP TABLE IF EXISTS rawsisuvacancies2025 CASCADE;
DROP TABLE IF EXISTS rawsisuvacancies2026 CASCADE;

-- Tabelas legadas de schema renomeado (se ainda existirem após o push)
DROP TABLE IF EXISTS institutionsinfoemec CASCADE;
DROP TABLE IF EXISTS institutionsinfosisu CASCADE;
DROP TABLE IF EXISTS opportunitiessisuvacancies CASCADE;

-- Tabela legada sem par em dev (0 registros, só existe no schema antigo)
DROP TABLE IF EXISTS passport_applications CASCADE;

-- Verificação final: confirmar que não sobraram tabelas inesperadas
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND (
    table_name LIKE '%2025%'
    OR table_name LIKE '%2026%'
    OR table_name IN ('institutionsinfoemec', 'institutionsinfosisu', 'opportunitiessisuvacancies', 'passport_applications')
  )
ORDER BY table_name;
-- Esperado: 0 linhas
