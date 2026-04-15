-- 20260415103000_allow_system_sender.sql
-- Sprint 5.5: Permite que o remetente de mensagens seja 'system' para triggers automáticos.

BEGIN;

-- 1. Remover a constraint antiga
ALTER TABLE public.chat_messages 
DROP CONSTRAINT IF EXISTS chat_messages_sender_check;

-- 2. Adicionar a nova constraint incluindo 'system'
ALTER TABLE public.chat_messages 
ADD CONSTRAINT chat_messages_sender_check 
CHECK (sender = ANY (ARRAY['user'::text, 'cloudinha'::text, 'system'::text]));

COMMIT;
