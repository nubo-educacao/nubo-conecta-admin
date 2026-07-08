-- 20260707180000_fix_clone_grain_and_rebuild_2026_2.sql
-- etl_clone_prouni_cycle (da 20260703120000) mapeava as vacancies origem->destino por
-- (course_id, shift) SEM scholarship_type. Com o grão novo (2 opps por curso+turno:
-- Integral e Parcial), o JOIN vira produto cartesiano 2x2 e o ON CONFLICT DO NOTHING
-- atribui vagas ao tipo de bolsa errado (detectado no curso-prova 48986: Matutino
-- Parcial recebeu as vagas da Integral).
-- 1. Recria o clone incluindo scholarship_type no mapeamento.
-- 2. Reconstrói o ProUni 2026.2 (delete + re-clone + refresh).

SET statement_timeout = '10min';

-- ====================================================================================
-- 1. etl_clone_prouni_cycle — grão (course, shift, scholarship_type) no mapeamento
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.etl_clone_prouni_cycle(
  p_source_program_id UUID,
  p_target_program_id UUID
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '10min'
AS $$
DECLARE
  v_src_year      INTEGER;
  v_src_semester  TEXT;
  v_tgt_year      INTEGER;
  v_tgt_semester  TEXT;
  v_log_id        UUID;
  v_opp_cloned    INTEGER := 0;
  v_vac_cloned    INTEGER := 0;
  v_errors        TEXT;
  v_detail_msg    TEXT;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_src_year, v_src_semester
  FROM public.programs WHERE id = p_source_program_id;
  IF v_src_year IS NULL THEN RAISE EXCEPTION 'Source program not found'; END IF;

  SELECT cycle_year, cycle_semester INTO v_tgt_year, v_tgt_semester
  FROM public.programs WHERE id = p_target_program_id;
  IF v_tgt_year IS NULL THEN RAISE EXCEPTION 'Target program not found'; END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
  VALUES (p_target_program_id, 'prouni_clone', 'running', now(), 0)
  RETURNING id INTO v_log_id;

  BEGIN
    -- 1. Clone opportunities
    WITH source_opps AS (
      SELECT * FROM public.opportunities
      WHERE opportunity_type = 'prouni'
        AND year = v_src_year
        AND semester = v_src_semester
    ),
    cloned_opps AS (
      INSERT INTO public.opportunities (
        course_id, semester, shift, scholarship_type, concurrency_type,
        year, opportunity_type, cutoff_score, raw_data,
        scholarship_tags, is_nubo_pick
      )
      SELECT
        so.course_id,
        v_tgt_semester,
        so.shift,
        so.scholarship_type,
        so.concurrency_type,
        v_tgt_year,
        so.opportunity_type,
        so.cutoff_score,
        so.raw_data,
        so.scholarship_tags,
        so.is_nubo_pick
      FROM source_opps so
      ON CONFLICT DO NOTHING
      RETURNING id
    )
    SELECT COUNT(*) INTO v_opp_cloned FROM cloned_opps;

    -- 2. Clone vacancies mapeando origem -> destino pelo GRÃO COMPLETO
    --    (course_id, shift, scholarship_type) — antes faltava scholarship_type,
    --    gerando pareamento cartesiano com o grão Integral/Parcial.
    WITH source_opps AS (
      SELECT id AS src_opp_id, course_id, shift, scholarship_type
      FROM public.opportunities
      WHERE opportunity_type = 'prouni'
        AND year = v_src_year
        AND semester = v_src_semester
    ),
    new_opps AS (
      SELECT id AS new_opp_id, course_id, shift, scholarship_type
      FROM public.opportunities
      WHERE opportunity_type = 'prouni'
        AND year = v_tgt_year
        AND semester = v_tgt_semester
    ),
    cloned_vacs AS (
      INSERT INTO public.opportunities_prouni_vacancies (
        opportunity_id,
        bolsas_ampla_ofertada, bolsas_cota_ofertada,
        bolsas_ampla_ocupada, bolsas_cota_ocupada
      )
      SELECT
        no.new_opp_id,
        pv.bolsas_ampla_ofertada,
        pv.bolsas_cota_ofertada,
        pv.bolsas_ampla_ocupada,
        pv.bolsas_cota_ocupada
      FROM public.opportunities_prouni_vacancies pv
      JOIN source_opps so ON so.src_opp_id = pv.opportunity_id
      JOIN new_opps no ON no.course_id = so.course_id
        AND no.shift IS NOT DISTINCT FROM so.shift
        AND no.scholarship_type IS NOT DISTINCT FROM so.scholarship_type
      ON CONFLICT (opportunity_id) DO NOTHING
      RETURNING opportunity_id
    )
    SELECT COUNT(*) INTO v_vac_cloned FROM cloned_vacs;

  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    v_detail_msg := 'Ciclo ProUni clonado com sucesso.' || chr(10)
      || '• Origem: ' || v_src_year || '.' || v_src_semester || chr(10)
      || '• Destino: ' || v_tgt_year || '.' || v_tgt_semester || chr(10)
      || '• Oportunidades clonadas: ' || v_opp_cloned || chr(10)
      || '• Vagas clonadas: ' || v_vac_cloned;

    UPDATE public.etl_run_logs
    SET status = 'success', errors = v_detail_msg, finished_at = now(),
        records_processed = v_opp_cloned + v_vac_cloned
    WHERE id = v_log_id;

    UPDATE public.programs SET is_fully_imported = true WHERE id = p_target_program_id;
    UPDATE public.programs SET prev_program_id = p_source_program_id WHERE id = p_target_program_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'opp_cloned', v_opp_cloned,
    'vac_cloned', v_vac_cloned,
    'log_id', v_log_id,
    'errors', v_errors
  );

EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('status', 'error', 'opp_cloned', 0, 'vac_cloned', 0, 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_clone_prouni_cycle(uuid, uuid) TO service_role, authenticated;

-- ====================================================================================
-- 2. Reconstrói o 2026.2 com o clone corrigido
-- ====================================================================================
DELETE FROM public.opportunities
WHERE opportunity_type = 'prouni' AND year = 2026 AND semester = '2';

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

REFRESH MATERIALIZED VIEW public.v_unified_opportunities;
