-- validate-prod.sql
-- ==================
-- Executar no SQL Editor do Supabase PROD após a migração (Card 3).
-- Verifica integridade dos dados preservados e migrados.
-- Plano: ca81e337 | Card 3

SELECT
  'user_profiles'           AS tabela, count(*) AS atual, 3058   AS esperado, count(*) = 3058   AS ok FROM user_profiles
UNION ALL SELECT
  'user_enem_scores',                  count(*),          606,                count(*) = 606             FROM user_enem_scores
UNION ALL SELECT
  'user_preferences',                  count(*),          1270,               count(*) = 1270            FROM user_preferences
UNION ALL SELECT
  'user_income',                       count(*),          466,                count(*) = 466             FROM user_income
UNION ALL SELECT
  'chat_messages',                     count(*),          42394,              count(*) = 42394           FROM chat_messages
UNION ALL SELECT
  'partners (preservado)',             count(*),          6,                  count(*) = 6               FROM partners
UNION ALL SELECT
  'partner_forms (preservado)',        count(*),          233,                count(*) = 233             FROM partner_forms
UNION ALL SELECT
  'student_applications (preservado)', count(*),          430,                count(*) = 430             FROM student_applications
UNION ALL SELECT
  'knowledge_documents (preservado)',  count(*),          5,                  count(*) = 5               FROM knowledge_documents
UNION ALL SELECT
  'institutions (dev)',                count(*),          138,                count(*) >= 138            FROM institutions
UNION ALL SELECT
  'campus (dev)',                      count(*),          1231,               count(*) >= 1231           FROM campus
UNION ALL SELECT
  'courses (dev)',                     count(*),          7539,               count(*) >= 7539           FROM courses
UNION ALL SELECT
  'opportunities (dev)',               count(*),          66289,              count(*) >= 66289          FROM opportunities
UNION ALL SELECT
  'partner_institutions (novo)',       count(*),          1,                  count(*) >= 1              FROM partner_institutions
UNION ALL SELECT
  'user_favorites (zerado)',           count(*),          0,                  count(*) = 0               FROM user_favorites
ORDER BY ok ASC, tabela;
-- Todas as linhas devem ter ok = true
