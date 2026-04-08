-- 20260406100500_alter_chat_messages_add_session_id.sql
-- Sprint 3: Adiciona session_id para agrupar mensagens por conversa

ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS session_id TEXT;

COMMENT ON COLUMN public.chat_messages.session_id IS 'UUID da sessão ativa. Permite agrupar mensagens por conversa.';

CREATE INDEX idx_chat_messages_session ON public.chat_messages(session_id);
