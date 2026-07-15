-- 20260708120500_normalize_preferred_shifts_labels.sql
-- Re-backfill de user_preferences.preferred_shifts: normaliza rótulos EAD legados
-- ('Curso a distância', 'EaD') para o vocabulário do form ('EAD').
-- O backfill da 20260707150000 foi desfeito pelo read-modify-write dos forms (valor
-- legado invisível nos checkboxes era re-gravado a cada save). O fix de raiz foi
-- aplicado no front (normalizeShifts no load do MatchOnboardingForm e PreferenciasTab);
-- esta migration limpa o dado existente. Idempotente.

UPDATE public.user_preferences
SET preferred_shifts = (
  SELECT array_agg(DISTINCT CASE WHEN s IN ('Curso a distância', 'EaD') THEN 'EAD' ELSE s END)
  FROM unnest(preferred_shifts) AS s
)
WHERE 'Curso a distância' = ANY(preferred_shifts)
   OR 'EaD' = ANY(preferred_shifts);
