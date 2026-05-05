-- =============================================================================
-- Migration: Seed match_config with V3 pillar weight keys
-- Sprint 7.0 — Adds performance_weight, preference_weight, idle_vacancy_boost
-- =============================================================================

-- V3 pillar weights (replace old granular score_composition keys)
INSERT INTO public.match_config (weight_key, weight_value, description, category) VALUES
  ('performance_weight', 0.40, 'Peso do Pilar 1: Performance & Elegibilidade (ENEM ponderado + nota de corte)', 'v3_pillar'),
  ('preference_weight', 0.30, 'Peso do Pilar 2: Alinhamento de Preferências (turno + instituição + curso)', 'v3_pillar'),
  ('idle_vacancy_boost', 5.0, 'Bônus aditivo máximo para vagas com alto índice de ociosidade (vagas_ociosas_2025)', 'boost')
ON CONFLICT (weight_key) DO UPDATE SET
  weight_value = EXCLUDED.weight_value,
  description = EXCLUDED.description,
  category = EXCLUDED.category;

-- Ensure location_weight is updated to V3 value (20% instead of 15%)
UPDATE public.match_config SET weight_value = 0.20, description = 'Peso do Pilar 3: Localização & Mobilidade (Haversine + preferência regional)', category = 'v3_pillar'
WHERE weight_key = 'location_weight';
