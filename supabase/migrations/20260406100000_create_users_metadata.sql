-- 20260406100000_create_users_metadata.sql
-- Sprint 3: Tabela de estado cognitivo do agente (LTM)
-- FK 1:1 com user_profiles, vinculada ao profile_id (não ao auth user)

CREATE TABLE public.users_metadata (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id UUID NOT NULL UNIQUE REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    cognitive_memory JSONB DEFAULT '{}'::jsonb,
    last_session_summary TEXT,
    conversation_starters JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.users_metadata IS 'Estado cognitivo do agente por perfil. Cada membro da família tem seu LTM único.';
COMMENT ON COLUMN public.users_metadata.cognitive_memory IS 'Sumário cognitivo condensado (~500 tokens). Fatos persistentes: objetivos, dificuldades, área de interesse.';
COMMENT ON COLUMN public.users_metadata.last_session_summary IS 'Resumo da última sessão (input para condensação).';
COMMENT ON COLUMN public.users_metadata.conversation_starters IS 'Últimas sugestões dinâmicas do Reasoning Agent, indexadas por page_route.';

CREATE INDEX idx_users_metadata_profile_id ON public.users_metadata(profile_id);
