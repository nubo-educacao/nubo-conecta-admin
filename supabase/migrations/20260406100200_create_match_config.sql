-- 20260406100200_create_match_config.sql
-- Sprint 3: Configuração do motor de match gerenciável via Admin /match-engine

CREATE TABLE public.match_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    weight_key TEXT NOT NULL UNIQUE,
    weight_value NUMERIC NOT NULL DEFAULT 1.0,
    description TEXT,
    category TEXT DEFAULT 'general',
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.match_config IS 'Pesos e multiplicadores do algoritmo de match. Editáveis via Admin /match-engine.';
COMMENT ON COLUMN public.match_config.weight_key IS 'Chave única do peso (ex: enem_weight, income_weight, partner_boost, location_weight).';
COMMENT ON COLUMN public.match_config.weight_value IS 'Valor numérico do multiplicador (ex: 1.15 para partner_boost).';

-- Seed: Pesos iniciais do motor de match
INSERT INTO public.match_config (weight_key, weight_value, description, category) VALUES
  ('enem_weight', 0.35, 'Peso da nota ENEM na composição do match score', 'score_composition'),
  ('income_weight', 0.20, 'Peso da renda familiar per capita', 'score_composition'),
  ('location_weight', 0.15, 'Peso da proximidade geográfica', 'score_composition'),
  ('course_interest_weight', 0.20, 'Peso da afinidade com áreas de interesse declaradas', 'score_composition'),
  ('quota_weight', 0.10, 'Peso do enquadramento em cotas', 'score_composition'),
  ('partner_boost', 1.15, 'Multiplicador de boost para oportunidades de parceiros (is_partner=true)', 'boost'),
  ('partner_boost_cap', 20.0, 'Diferença máxima de match (pp) que o boost pode superar. Regra: MEC 95% SEMPRE acima de Parceiro 60% boosted.', 'boost');
