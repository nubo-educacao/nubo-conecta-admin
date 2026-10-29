-- =============================================================================
-- Migration: agent_errors_session_id_text
-- A Cloudinha grava em agent_errors o id de sessão do chat (o mesmo de
-- agent_turns.session_id / chat_messages.session_id, ambos text), no formato
-- "4ll12zt0hhhmvpzhxob" — não é uuid. Em produção a coluna é uuid
-- (production_baseline.sql), então todo insert falhava com
-- invalid input syntax for type uuid e o agente só registrava o erro no console:
-- agent_errors não recebe nada desde 30/05/2026 (o último registro é dessa data).
-- O dev já tinha a coluna em text por ajuste manual, sem migration.
--
-- Correção: session_id passa a ser text. Os valores uuid existentes viram texto.
-- Sem views, funções ou índices dependentes da coluna.
-- =============================================================================

ALTER TABLE public.agent_errors ALTER COLUMN session_id TYPE text USING session_id::text;
