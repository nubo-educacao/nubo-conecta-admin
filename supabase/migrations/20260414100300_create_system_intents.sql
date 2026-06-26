-- 20260414100300_create_system_intents.sql
-- Sprint 5.5: Tabela de System Intents gerenciáveis pelo Admin.
-- Permite configurar triggers contextuais da Cloudinha sem deploy.

CREATE TABLE public.system_intents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    command TEXT NOT NULL,
    trigger_route TEXT,                                    -- regex da rota (ex: "^/oportunidades/.+$")
    trigger_type TEXT NOT NULL DEFAULT 'route_change',     -- "route_change" | "manual" | "timer"
    open_drawer BOOLEAN DEFAULT false,
    delay_ms INT DEFAULT 0,                             -- Delay (ms) antes de abrir o drawer
    response_template TEXT,                                -- Template de resposta (com {{placeholders}})
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.system_intents IS 'Configuração de system intents da Cloudinha, gerenciáveis via Admin /agent-config.';
COMMENT ON COLUMN public.system_intents.command IS 'Identificador do comando: page_context, get_starters, clear_session, ping.';
COMMENT ON COLUMN public.system_intents.trigger_route IS 'Regex da rota que dispara o intent automaticamente (ex: ^/oportunidades/.+$). NULL para intents manuais.';
COMMENT ON COLUMN public.system_intents.trigger_type IS 'Tipo de trigger: route_change (automático por rota), manual (botão), timer (delay fixo).';
COMMENT ON COLUMN public.system_intents.open_drawer IS 'Se true, a Cloudinha abre o drawer automaticamente ao disparar este intent.';
COMMENT ON COLUMN public.system_intents.delay_ms IS 'Delay em milissegundos antes de abrir o drawer (só usado se open_drawer=true).';
COMMENT ON COLUMN public.system_intents.response_template IS 'Template de resposta contextual. Suporta placeholders como {{title}}, {{institution}}.';

-- RLS: Leitura pública (agente + app precisam ler), escrita apenas admin
ALTER TABLE public.system_intents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "system_intents_select_all" ON public.system_intents
    FOR SELECT USING (true);

CREATE POLICY "system_intents_admin_all" ON public.system_intents
    FOR ALL USING (public.is_backoffice_admin());

-- Seed: System intents iniciais
INSERT INTO public.system_intents (command, trigger_route, trigger_type, open_drawer, delay_ms, response_template, description) VALUES
(
    'page_context',
    '^/oportunidades/.+$',
    'route_change',
    true,
    0,
    'Olá! Vejo que você está explorando **{{title}}** em {{institution}}. 🎓

Posso te ajudar a entender os requisitos, prazos ou como se candidatar. O que você gostaria de saber?',
    'Envia mensagem contextual da Cloudinha quando o usuário acessa uma oportunidade.'
),
(
    'get_starters',
    NULL,
    'manual',
    false,
    0,
    NULL,
    'Busca os Conversation Starters da rota atual ao abrir o drawer.'
),
(
    'clear_session',
    NULL,
    'manual',
    false,
    0,
    NULL,
    'Limpa o histórico da sessão de chat atual.'
),
(
    'ping',
    NULL,
    'manual',
    false,
    0,
    NULL,
    'Health check do pipeline da Cloudinha.'
);
