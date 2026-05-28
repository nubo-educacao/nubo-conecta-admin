-- Add is_treineiro flag to user_enem_scores
-- Indicates whether the score is from a Treineiro/Simulado (non-official) ENEM attempt.
-- Treineiro scores are stored and shown in the app but flagged visually
-- and receive lower priority in the match engine over official scores.

ALTER TABLE public.user_enem_scores
  ADD COLUMN IF NOT EXISTS is_treineiro BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.user_enem_scores.is_treineiro IS
  'True when the score is from a Treineiro/Simulado attempt (unofficial). '
  'Match engine and SisuScoreDisplay prefer official scores; treineiro is used as fallback.';
