-- =============================================================================
-- Migration: sisu_clone_cycle  (NUB-SUP-90)
-- Herança (clonagem) de ciclo SiSU pela tela de Importação, como já existe
-- para o ProUni.
--
-- 1. Backfill de programs.is_fully_imported para SiSU: o SiSU 2026.1 foi
--    carregado em 09–12/06/2026, depois do backfill 20260609175300 e sem passar
--    pela conclusão do pipeline (nenhum etl_run_logs de sisu em PROD). A flag
--    ficou false e o ciclo não aparecia em "Ciclo Anterior". Mesma regra do
--    backfill original: ciclo com notas de corte = base importada.
-- 2. etl_clone_sisu_cycle(source, target): copia opportunities SiSU e suas
--    opportunities_sisu_vacancies para o ciclo destino. SiSU não tem chave
--    natural única em opportunities, então o vínculo vaga→oportunidade é feito
--    por um mapa de ids (src_id → new_id), não por join de colunas.
-- 3. etl_rollback_log: 'sisu_clone' é revertido como 'sisu_vacancies'
--    (apaga vagas e oportunidades SiSU do ciclo).
-- 4. etl_import_refresh_opportunities: trava por advisory lock. A função roda
--    numa transação só, então o log 'running' não é visível para a tela até o
--    fim; um segundo disparo esperava o lock do REFRESH CONCURRENTLY e caía em
--    "canceling statement due to lock timeout" (29/10/2026 09:35). Agora o
--    segundo disparo retorna erro imediato e explícito.
-- =============================================================================

-- 1. Backfill ------------------------------------------------------------------
UPDATE public.programs p
SET is_fully_imported = true
WHERE p.type = 'sisu'
  AND p.is_fully_imported = false
  AND EXISTS (
    SELECT 1 FROM public.opportunities o
    WHERE o.opportunity_type = 'sisu'
      AND o.year = p.cycle_year
      AND o.semester = p.cycle_semester
      AND o.cutoff_score IS NOT NULL
  );

-- 2. Clonagem SiSU --------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.etl_clone_sisu_cycle(p_source_program_id uuid, p_target_program_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '10min'
AS $function$
DECLARE
  v_src_type      TEXT;
  v_src_year      INTEGER;
  v_src_semester  TEXT;
  v_tgt_type      TEXT;
  v_tgt_year      INTEGER;
  v_tgt_semester  TEXT;
  v_existing      INTEGER;
  v_log_id        UUID;
  v_opp_cloned    INTEGER := 0;
  v_vac_cloned    INTEGER := 0;
  v_errors        TEXT;
  v_detail_msg    TEXT;
BEGIN
  SELECT type, cycle_year, cycle_semester INTO v_src_type, v_src_year, v_src_semester
  FROM public.programs WHERE id = p_source_program_id;
  IF v_src_year IS NULL THEN RAISE EXCEPTION 'Ciclo de origem não encontrado'; END IF;

  SELECT type, cycle_year, cycle_semester INTO v_tgt_type, v_tgt_year, v_tgt_semester
  FROM public.programs WHERE id = p_target_program_id;
  IF v_tgt_year IS NULL THEN RAISE EXCEPTION 'Ciclo de destino não encontrado'; END IF;

  IF v_src_type <> 'sisu' OR v_tgt_type <> 'sisu' THEN
    RAISE EXCEPTION 'Origem e destino precisam ser ciclos SiSU';
  END IF;
  IF p_source_program_id = p_target_program_id THEN
    RAISE EXCEPTION 'Origem e destino são o mesmo ciclo';
  END IF;

  -- Um clone por destino de cada vez (duplo clique / duas abas).
  IF NOT pg_try_advisory_xact_lock(hashtext('etl_clone_sisu_cycle:' || p_target_program_id::text)) THEN
    RAISE EXCEPTION 'Já existe uma clonagem em andamento para este ciclo';
  END IF;

  -- Clonar sobre um ciclo que já tem dados duplicaria tudo: exige rollback antes.
  SELECT count(*) INTO v_existing FROM public.opportunities
  WHERE opportunity_type = 'sisu' AND year = v_tgt_year AND semester = v_tgt_semester;
  IF v_existing > 0 THEN
    RAISE EXCEPTION 'O ciclo destino já tem % oportunidades SiSU. Faça o rollback antes de clonar.', v_existing;
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
  VALUES (p_target_program_id, 'sisu_clone', 'running', now(), 0)
  RETURNING id INTO v_log_id;

  BEGIN
    CREATE TEMP TABLE _sisu_clone_map ON COMMIT DROP AS
      SELECT o.id AS src_id, gen_random_uuid() AS new_id
      FROM public.opportunities o
      WHERE o.opportunity_type = 'sisu'
        AND o.year = v_src_year
        AND o.semester = v_src_semester;

    INSERT INTO public.opportunities (
      id, course_id, semester, shift, scholarship_type, concurrency_type,
      year, opportunity_type, cutoff_score, raw_data,
      scholarship_tags, is_nubo_pick, concurrency_tags
    )
    SELECT
      m.new_id, o.course_id, v_tgt_semester, o.shift, o.scholarship_type, o.concurrency_type,
      v_tgt_year, o.opportunity_type, o.cutoff_score, o.raw_data,
      o.scholarship_tags, o.is_nubo_pick, o.concurrency_tags
    FROM _sisu_clone_map m
    JOIN public.opportunities o ON o.id = m.src_id;
    GET DIAGNOSTICS v_opp_cloned = ROW_COUNT;

    INSERT INTO public.opportunities_sisu_vacancies (
      opportunity_id, qt_semestre, nu_vagas_autorizadas, qt_vagas_ofertadas, qt_vagas_ofertadas_prev,
      nu_percentual_bonus, tp_mod_concorrencia, tp_cota, ds_mod_concorrencia,
      perc_uf_ibge_ppi, perc_uf_ibge_pp, perc_uf_ibge_i, perc_uf_ibge_q, perc_uf_ibge_pcd,
      nu_perc_lei, nu_perc_ppi, nu_perc_pp, nu_perc_i, nu_perc_q, nu_perc_pcd,
      peso_redacao, peso_linguagens, peso_matematica, peso_ciencias_humanas, peso_ciencias_natureza,
      nota_minima_redacao, nota_minima_linguagens, nota_minima_matematica,
      nota_minima_ciencias_humanas, nota_minima_ciencias_natureza,
      nu_media_minima_enem, qt_inscricao
    )
    SELECT
      m.new_id, v.qt_semestre, v.nu_vagas_autorizadas, v.qt_vagas_ofertadas, v.qt_vagas_ofertadas_prev,
      v.nu_percentual_bonus, v.tp_mod_concorrencia, v.tp_cota, v.ds_mod_concorrencia,
      v.perc_uf_ibge_ppi, v.perc_uf_ibge_pp, v.perc_uf_ibge_i, v.perc_uf_ibge_q, v.perc_uf_ibge_pcd,
      v.nu_perc_lei, v.nu_perc_ppi, v.nu_perc_pp, v.nu_perc_i, v.nu_perc_q, v.nu_perc_pcd,
      v.peso_redacao, v.peso_linguagens, v.peso_matematica, v.peso_ciencias_humanas, v.peso_ciencias_natureza,
      v.nota_minima_redacao, v.nota_minima_linguagens, v.nota_minima_matematica,
      v.nota_minima_ciencias_humanas, v.nota_minima_ciencias_natureza,
      v.nu_media_minima_enem, v.qt_inscricao
    FROM _sisu_clone_map m
    JOIN public.opportunities_sisu_vacancies v ON v.opportunity_id = m.src_id;
    GET DIAGNOSTICS v_vac_cloned = ROW_COUNT;

  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    v_detail_msg := 'Ciclo SiSU clonado com sucesso.' || chr(10)
      || '- Origem: ' || v_src_year || '.' || v_src_semester || chr(10)
      || '- Destino: ' || v_tgt_year || '.' || v_tgt_semester || chr(10)
      || '- Oportunidades clonadas: ' || v_opp_cloned || chr(10)
      || '- Vagas clonadas: ' || v_vac_cloned;

    UPDATE public.etl_run_logs
    SET status = 'success', errors = v_detail_msg, finished_at = now(),
        records_processed = v_opp_cloned + v_vac_cloned
    WHERE id = v_log_id;

    UPDATE public.programs
    SET is_fully_imported = true, prev_program_id = p_source_program_id
    WHERE id = p_target_program_id;
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
$function$;

REVOKE ALL ON FUNCTION public.etl_clone_sisu_cycle(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.etl_clone_sisu_cycle(uuid, uuid) TO authenticated, service_role;

-- 3. Rollback reconhece 'sisu_clone' --------------------------------------------
CREATE OR REPLACE FUNCTION public.etl_rollback_log(p_log_id uuid, p_limit integer DEFAULT 500, p_active_rollback_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_program_id uuid;
  v_etl_type text;
  v_status text;
  v_year integer;
  v_semester text;
  v_new_log_id uuid;
  v_new_etl_type text;
  v_detail_msg text;

  v_opps_deleted integer := 0;
  v_vacancies_deleted integer := 0;
  v_prouni_vac_deleted integer := 0;
  v_sisu_vac_updated integer := 0;

  v_has_more boolean := false;
  v_total_processed integer := 0;
BEGIN
  SET LOCAL statement_timeout = '10min';

  SELECT program_id, etl_type, status INTO v_program_id, v_etl_type, v_status
  FROM public.etl_run_logs WHERE id = p_log_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Log not found';
  END IF;

  IF v_status = 'running' THEN
    RAISE EXCEPTION 'Cannot rollback a running ETL operation';
  END IF;

  IF v_etl_type LIKE 'rollback_%' THEN
    RAISE EXCEPTION 'Cannot rollback a rollback operation';
  END IF;

  -- Guard: never mutate a cycle that has another import/rollback in flight.
  IF v_program_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.etl_run_logs
    WHERE program_id = v_program_id
      AND status = 'running'
      AND id <> COALESCE(p_active_rollback_id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) THEN
    RAISE EXCEPTION 'Há outra execução em andamento para este ciclo. Aguarde antes de fazer rollback.';
  END IF;

  v_new_etl_type := 'rollback_' || v_etl_type;

  IF p_active_rollback_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (v_program_id, v_new_etl_type, 'running', now(), 0)
    RETURNING id INTO v_new_log_id;
  ELSE
    v_new_log_id := p_active_rollback_id;
  END IF;

  IF v_program_id IS NOT NULL THEN
    SELECT cycle_year, cycle_semester INTO v_year, v_semester
    FROM public.programs WHERE id = v_program_id;

    UPDATE public.programs SET is_fully_imported = false WHERE id = v_program_id;
  END IF;

  BEGIN
    IF v_etl_type IN ('sisu_vacancies', 'sisu_clone') THEN
      DELETE FROM public.opportunities_sisu_vacancies sv
      WHERE sv.ctid IN (
        SELECT sv_inner.ctid FROM public.opportunities_sisu_vacancies sv_inner
        JOIN public.opportunities o ON sv_inner.opportunity_id = o.id
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
        LIMIT p_limit
      );
      GET DIAGNOSTICS v_vacancies_deleted = ROW_COUNT;

      IF v_vacancies_deleted < p_limit THEN
        DELETE FROM public.opportunities o
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
        AND o.id IN (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year AND o_inner.semester = v_semester AND o_inner.opportunity_type = 'sisu'
          LIMIT (p_limit - v_vacancies_deleted)
        );
        GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_vacancies_deleted + COALESCE(v_opps_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'sisu' THEN
      WITH to_update AS (
        SELECT sv_inner.opportunity_id, sv_inner.tp_mod_concorrencia
        FROM public.opportunities_sisu_vacancies sv_inner
        JOIN public.opportunities o ON sv_inner.opportunity_id = o.id
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
          AND sv_inner.qt_inscricao IS NOT NULL
        LIMIT p_limit
      )
      UPDATE public.opportunities_sisu_vacancies sv
      SET qt_inscricao = NULL, updated_at = now()
      FROM to_update
      WHERE sv.opportunity_id = to_update.opportunity_id AND sv.tp_mod_concorrencia = to_update.tp_mod_concorrencia;
      GET DIAGNOSTICS v_sisu_vac_updated = ROW_COUNT;

      IF v_sisu_vac_updated < p_limit THEN
        DELETE FROM public.opportunities o
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu'
          AND NOT EXISTS (
            SELECT 1 FROM public.opportunities_sisu_vacancies sv WHERE sv.opportunity_id = o.id
          )
        AND o.id IN (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year AND o_inner.semester = v_semester AND o_inner.opportunity_type = 'sisu'
            AND NOT EXISTS (
              SELECT 1 FROM public.opportunities_sisu_vacancies sv_inner WHERE sv_inner.opportunity_id = o_inner.id
            )
          LIMIT (p_limit - v_sisu_vac_updated)
        );
        GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_sisu_vac_updated + COALESCE(v_opps_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'prouni_base' OR v_etl_type = 'prouni_clone' THEN
      -- Delete opportunities_prouni_vacancies in batches (opps deleted once vacancies drained).
      DELETE FROM public.opportunities_prouni_vacancies pv
      WHERE pv.ctid IN (
        SELECT pv_inner.ctid FROM public.opportunities_prouni_vacancies pv_inner
        JOIN public.opportunities o ON o.id = pv_inner.opportunity_id
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni'
        LIMIT p_limit
      );
      GET DIAGNOSTICS v_prouni_vac_deleted = ROW_COUNT;

      IF v_prouni_vac_deleted < p_limit THEN
        DELETE FROM public.opportunities o
        WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni'
        AND o.id IN (
          SELECT o_inner.id FROM public.opportunities o_inner
          WHERE o_inner.year = v_year AND o_inner.semester = v_semester AND o_inner.opportunity_type = 'prouni'
          LIMIT (p_limit - v_prouni_vac_deleted)
        );
        GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;
      END IF;

      v_has_more := (v_prouni_vac_deleted + COALESCE(v_opps_deleted, 0)) >= p_limit;

    ELSIF v_etl_type = 'emec' OR v_etl_type LIKE 'refresh_%' THEN
      RAISE EXCEPTION 'Cannot rollback global or refresh ETL operations';
    ELSE
      RAISE EXCEPTION 'Unknown ETL type for rollback: %', v_etl_type;
    END IF;

    v_total_processed := COALESCE(v_vacancies_deleted, 0) + COALESCE(v_opps_deleted, 0)
      + COALESCE(v_prouni_vac_deleted, 0) + COALESCE(v_sisu_vac_updated, 0);

    UPDATE public.etl_run_logs
    SET records_processed = COALESCE(records_processed, 0) + v_total_processed
    WHERE id = v_new_log_id;

    IF NOT v_has_more THEN
      v_detail_msg := 'Rollback concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Tipo revertido: ' || v_etl_type || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

      UPDATE public.etl_run_logs
      SET status = 'success', errors = v_detail_msg, finished_at = now()
      WHERE id = v_new_log_id;
    END IF;

    RETURN jsonb_build_object(
      'status', 'success',
      'message', 'Rollback batch processed.',
      'processed', v_total_processed,
      'has_more', v_has_more,
      'log_id', v_new_log_id
    );
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.etl_run_logs
    SET status = 'error', errors = SQLERRM, finished_at = now()
    WHERE id = v_new_log_id;

    RAISE EXCEPTION 'Rollback failed: %', SQLERRM;
  END;
END;
$function$;

-- 4. Sincronização: um disparo por vez ------------------------------------------
CREATE OR REPLACE FUNCTION public.etl_import_refresh_opportunities()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '10min'
AS $function$
DECLARE
  v_log_id UUID;
  v_errors TEXT;
  v_processed INTEGER := 0;
  v_cycles TEXT;

  v_opps_count INTEGER := 0;
  v_inst_count INTEGER := 0;
  v_campus_count INTEGER := 0;
  v_details TEXT;
BEGIN
  -- O log 'running' só fica visível no commit; a trava é o advisory lock.
  IF NOT pg_try_advisory_xact_lock(hashtext('etl_import_refresh_opportunities')) THEN
    RETURN jsonb_build_object(
      'processed', 0,
      'status', 'error',
      'errors', 'Já existe uma Sincronização Opportunities em andamento. Aguarde ela terminar.'
    );
  END IF;

  INSERT INTO public.etl_run_logs (etl_type, status, started_at)
  VALUES ('refresh_opportunities', 'running', now())
  RETURNING id INTO v_log_id;

  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.v_unified_opportunities;

    -- Contar registros pós-refresh
    SELECT count(*) INTO v_processed FROM public.v_unified_opportunities;
    v_opps_count := v_processed;

    SELECT count(*) INTO v_inst_count FROM public.v_unified_institutions;

    SELECT count(DISTINCT c.campus_id) INTO v_campus_count
    FROM public.opportunities o
    JOIN public.programs p ON p.cycle_year = o.year AND p.cycle_semester = o.semester AND p.type = o.opportunity_type
    JOIN public.courses c ON c.id = o.course_id
    WHERE p.status IN ('incoming', 'opened', 'closed');

    -- Listar ciclos ativos sincronizados
    SELECT string_agg(title || ' (' || status || ')', ', ')
    INTO v_cycles
    FROM public.programs
    WHERE status != 'inactive';

    v_details := 'Ciclos Sincronizados: ' || COALESCE(v_cycles, 'Nenhum') || E'\n' ||
                 'Oportunidades (Cursos): ' || v_opps_count || E'\n' ||
                 'Câmpus: ' || COALESCE(v_campus_count, 0) || E'\n' ||
                 'Instituições: ' || v_inst_count;

  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    UPDATE public.etl_run_logs
    SET status = 'success',
        records_processed = v_processed,
        errors = v_details,
        finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error',
        errors = v_errors,
        finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$function$;
