-- 20260406100300_create_user_opportunity_matches.sql
-- Sprint 3: Resultados persistidos do motor de match por perfil

CREATE TABLE public.user_opportunity_matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    unified_opportunity_id TEXT NOT NULL,
    match_score NUMERIC(5,2) NOT NULL DEFAULT 0.00,
    match_details JSONB DEFAULT '{}'::jsonb,
    generated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.user_opportunity_matches IS 'Resultados de match por perfil. Regenerados ao clicar "Gerar Match" ou "Refazer Match".';
COMMENT ON COLUMN public.user_opportunity_matches.unified_opportunity_id IS 'ID da v_unified_opportunities (ex: mec_123 ou partner_456).';
COMMENT ON COLUMN public.user_opportunity_matches.match_score IS 'Percentual de compatibilidade (0.00 a 100.00).';
COMMENT ON COLUMN public.user_opportunity_matches.match_details IS 'Breakdown: { enem_component: 30.5, income_component: 18.0, ... }';

CREATE INDEX idx_uom_profile ON public.user_opportunity_matches(profile_id);
CREATE INDEX idx_uom_score ON public.user_opportunity_matches(match_score DESC);
CREATE INDEX idx_uom_profile_generated ON public.user_opportunity_matches(profile_id, generated_at DESC);
