-- 20260414100400_fix_system_intents_column.sql
-- Corrige: response_template → trigger_message
-- System intents enviam uma mensagem invisível ao pipeline LLM,
-- como se o usuário tivesse escrito, mas sem aparecer na tela.
-- A Cloudinha processa normalmente e gera uma resposta real.

ALTER TABLE public.system_intents
    RENAME COLUMN response_template TO trigger_message;

COMMENT ON COLUMN public.system_intents.trigger_message IS
    'Mensagem invisível enviada ao pipeline LLM da Cloudinha (como se fosse do usuário, mas oculta na UI). '
    'Suporta placeholders: {{title}}, {{institution}}, {{route}}. '
    'Ex: "O usuário está vendo a oportunidade {{title}} em {{institution}}. Ofereça ajuda contextual."';

-- Atualizar o seed do page_context
UPDATE public.system_intents
SET trigger_message = 'O usuário acabou de abrir a página de uma oportunidade educacional. Os dados são: título={{title}}, instituição={{institution}}. Gere uma mensagem curta e proativa oferecendo ajuda sobre essa oportunidade.'
WHERE command = 'page_context';
