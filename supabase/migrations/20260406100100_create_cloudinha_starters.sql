-- 20260406100100_create_cloudinha_starters.sql
-- Sprint 3: Starters estáticos da Cloudinha gerenciáveis pelo Admin

CREATE TABLE public.cloudinha_starters (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    page_route TEXT NOT NULL,
    route_priority INT DEFAULT 0,
    intro_message TEXT,
    starters JSONB DEFAULT '[]'::jsonb,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.cloudinha_starters IS 'Conversation starters estáticos por rota, gerenciados via Admin /agent-config.';
COMMENT ON COLUMN public.cloudinha_starters.page_route IS 'Rota do app (ex: /oportunidades, /courses/:id). Maior route_priority prevalece em colisões.';
COMMENT ON COLUMN public.cloudinha_starters.starters IS 'Array JSON de strings: ["Pergunta 1?", "Pergunta 2?", "Pergunta 3?"]';

CREATE INDEX idx_cloudinha_starters_route ON public.cloudinha_starters(page_route);

-- Seed inicial: Starters para rotas principais
INSERT INTO public.cloudinha_starters (page_route, route_priority, intro_message, starters) VALUES
  ('/', 0, 'Oi! Sou a Cloudinha, sua guia educacional. Como posso te ajudar hoje?', '["Quais são as melhores bolsas para mim?", "Como funciona o Sisu?", "Me ajude a encontrar um curso"]'),
  ('/oportunidades', 0, 'Estou aqui para te ajudar a encontrar a melhor vaga!', '["Quais cursos combinam comigo?", "O que é nota de corte?", "Me explique as cotas"]'),
  ('/instituicoes', 0, 'Quer saber mais sobre alguma instituição?', '["Qual a melhor universidade perto de mim?", "O que significa IGC?", "Quais faculdades são parceiras do Nubo?"]'),
  ('/candidaturas', 0, 'Quer saber como está o andamento da sua inscrição?', '["Como funciona o processo de candidatura?", "Quais documentos preciso?", "Posso me candidatar a mais de uma vaga?"]');
