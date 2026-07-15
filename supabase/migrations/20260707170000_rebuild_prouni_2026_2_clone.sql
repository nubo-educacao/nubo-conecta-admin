-- 20260707170000_rebuild_prouni_2026_2_clone.sql
-- O re-clone do ProUni 2026.2 (07/07 13:12) rodou SEM rollback do clone anterior
-- (dado colapsado do grão antigo): sem constraint única no grão, os dois clones
-- empilharam — 133.400 opps no ciclo (61.064 duplicadas).
-- Reconstrói o ciclo 2026.2 do zero a partir do 2025.2 já reimportado (grão correto):
--   1. Apaga TODAS as opps ProUni 2026.2 (vacancies caem via FK ON DELETE CASCADE).
--   2. Re-clona via etl_clone_prouni_cycle (grava etl_run_logs — auditoria preservada).
--   3. REFRESH da matview.
-- IDs dos programas (verificados em prod):
--   2025.2 (origem): aa14b186-19ff-46a3-a421-e77f143a065a
--   2026.2 (destino): da4632f8-a257-44f7-af31-e39631c30f73

SET statement_timeout = '10min';

-- 1. Limpa o ciclo 2026.2 por completo (clone velho + clone novo)
DELETE FROM public.opportunities
WHERE opportunity_type = 'prouni' AND year = 2026 AND semester = '2';

-- 2. Re-clona 2025.2 -> 2026.2 (aborta a migration se o clone reportar erro)
DO $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT public.etl_clone_prouni_cycle(
    'aa14b186-19ff-46a3-a421-e77f143a065a'::uuid,  -- origem 2025.2
    'da4632f8-a257-44f7-af31-e39631c30f73'::uuid   -- destino 2026.2
  ) INTO v_result;

  IF v_result->>'status' <> 'success' THEN
    RAISE EXCEPTION 'Clone falhou: %', v_result->>'errors';
  END IF;

  RAISE NOTICE 'Clone OK: % opps, % vagas', v_result->>'opp_cloned', v_result->>'vac_cloned';
END;
$$;

-- 3. Matview reflete o ciclo reconstruído
REFRESH MATERIALIZED VIEW public.v_unified_opportunities;
