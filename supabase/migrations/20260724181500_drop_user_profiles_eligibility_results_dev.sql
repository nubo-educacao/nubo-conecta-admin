-- 20260724181500_drop_user_profiles_eligibility_results_dev.sql
--
-- Completa o alinhamento com prod (20260724180000): prod não tem mais
-- user_profiles.eligibility_results, só student_applications.eligibility_results.
-- Confirmado de novo, imediatamente antes deste DROP, que a coluna está vazia
-- para todo usuário no dev (0 linhas com valor não-nulo) — nenhum dado
-- perdido. Nenhuma RPC/view lê mais up.eligibility_results desde 20260724180000.

ALTER TABLE public.user_profiles
  DROP COLUMN IF EXISTS eligibility_results;
