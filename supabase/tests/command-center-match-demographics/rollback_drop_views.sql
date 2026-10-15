-- Reversão da migration 20261015204255 (sem dados a restaurar: ela não escreve
-- em tabela nenhuma). Ordem:
--   1. reaplicar supabase/migrations/20260811160000_command_center_health_demographics.sql
--      (RPC volta à definição anterior, que não lê as views);
--   2. rodar este arquivo.
DROP VIEW IF EXISTS public.vw_user_demographics_resolved;
DROP VIEW IF EXISTS public.vw_user_match_evidence;
