-- 20260829120000_fix_prouni_etl_on_conflict_target.sql
-- Correcao do ETL ProUni (Sprint 9.0 / feat/unify-etl-data-pipeline-ui)
--
-- BUG 1 -- "constraint uq_opportunities_prouni_concurrency for table opportunities does not exist"
--   A migracao 20260828100000 cria uq_opportunities_prouni_concurrency como INDICE UNICO PARCIAL
--   (CREATE UNIQUE INDEX ... WHERE ...). O PostgreSQL so aceita "ON CONFLICT ON CONSTRAINT <nome>"
--   para constraints de tabela (ALTER TABLE ... ADD CONSTRAINT), e um indice parcial nao e uma
--   constraint -- dai a excecao acima ao rodar etl_import_prouni / etl_clone_prouni_cycle.
--   Correcao: usar inferencia por colunas + predicado do indice parcial:
--     ON CONFLICT (course_id, opportunity_type, year, semester, shift, scholarship_type, concurrency_type)
--     WHERE opportunity_type = 'prouni' AND concurrency_type IS NOT NULL
--     DO NOTHING
--
-- BUG 2 -- scholarship_tags com escape invalido
--   A versao 20260828110000 gravava '[[\"BOLSA_INTEGRAL\"]]'::jsonb dentro do corpo dollar-quoted.
--   Com standard_conforming_strings = on a barra invertida e literal, logo o texto chega ao cast
--   como [[\"BOLSA_INTEGRAL\"]] e o Postgres lanca "invalid input syntax for type json".
--   Isso quebrava o ultimo lote de prouni_base (bloco fora do EXCEPTION interno).
--   Correcao: '[["BOLSA_INTEGRAL"]]'::jsonb / '[["BOLSA_PARCIAL"]]'::jsonb.
--
-- NAO ha nova coluna: o ProUni continua usando estritamente opportunities.concurrency_type,
-- a mesma coluna ja utilizada pelo SiSU. Assinaturas das funcoes preservadas (CREATE OR REPLACE
-- sem overload).

CREATE OR REPLACE FUNCTION public.etl_import_prouni(
  p_program_id uuid,
  p_limit integer DEFAULT 5000,
  p_after_ctid text DEFAULT NULL,
  p_log_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '10min'
AS $$
DECLARE
  v_year              INTEGER;
  v_semester          TEXT;
  v_log_id            UUID;
  v_processed         INTEGER := 0;
  v_errors            TEXT;
  v_raw_count         INTEGER;
  v_inst_count        INTEGER;
  v_campus_count      INTEGER;
  v_course_count      INTEGER;
  v_opp_count         INTEGER;
  v_opp_integral      INTEGER;
  v_opp_parcial       INTEGER;
  v_opp_ampla         INTEGER;
  v_opp_cota          INTEGER;
  v_vacancies_count   INTEGER;
  v_total_ofertada    BIGINT;
  v_total_ocupada     BIGINT;
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
  v_batch_rows        INTEGER := 0;
  v_next_ctid         TID;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawprouni;

  IF p_log_id IS NULL THEN
    PERFORM public.etl_reap_stale_runs();

    IF EXISTS (
      SELECT 1 FROM public.etl_run_logs
      WHERE program_id = p_program_id AND etl_type = 'prouni_base' AND status = 'running'
    ) THEN
      RAISE EXCEPTION 'Ja existe uma importacao ProUni em andamento para este ciclo. Aguarde ou pare a execucao atual.';
    END IF;

    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed, backend_pid)
    VALUES (p_program_id, 'prouni_base', 'running', now(), 0, pg_backend_pid())
    RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
    UPDATE public.etl_run_logs SET backend_pid = pg_backend_pid() WHERE id = v_log_id;
  END IF;

  BEGIN
    DROP TABLE IF EXISTS temp_batch;
    CREATE TEMP TABLE temp_batch ON COMMIT DROP AS
    SELECT r.*, r.ctid AS _src_ctid
    FROM public.rawprouni r
    WHERE r.ctid > COALESCE(p_after_ctid::tid, '(0,0)'::tid)
    ORDER BY r.ctid
    LIMIT p_limit;

    SELECT count(*) INTO v_batch_rows FROM temp_batch;
    SELECT _src_ctid INTO v_next_ctid FROM temp_batch ORDER BY _src_ctid DESC LIMIT 1;

    -- 1. Institutions
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT ON (r."CO_IES"::text) r."CO_IES"::text, r."NO_IES"
    FROM temp_batch r
    WHERE r."CO_IES" IS NOT NULL
    ORDER BY r."CO_IES"::text, r."NO_IES"
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;

    -- 2. Campus
    INSERT INTO public.campus (institution_id, external_code, name, city, state)
    SELECT DISTINCT ON (r."CO_CAMPUS"::text) i.id, r."CO_CAMPUS"::text, r."NO_CAMPUS",
      COALESCE(
        (SELECT c.name FROM public.cities c
         WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(r."NO_MUNICIPIO_CAMPUS"))
           AND c.state = r."SG_UF_CAMPUS" LIMIT 1),
        r."NO_MUNICIPIO_CAMPUS"
      ) AS city,
      r."SG_UF_CAMPUS"
    FROM temp_batch r
    JOIN public.institutions i ON i.external_code = r."CO_IES"::text
    WHERE r."CO_CAMPUS" IS NOT NULL
    ORDER BY r."CO_CAMPUS"::text, r."NO_CAMPUS"
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name, city = EXCLUDED.city, state = EXCLUDED.state;

    -- 3. Courses
    INSERT INTO public.courses (campus_id, course_code, course_name)
    SELECT DISTINCT ON (ca.id, r."CO_CURSO"::text) ca.id, r."CO_CURSO"::text, r."NO_CURSO"
    FROM temp_batch r
    JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
    WHERE r."CO_CURSO" IS NOT NULL
    ORDER BY ca.id, r."CO_CURSO"::text, r."NO_CURSO"
    ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name;

    -- 4. Opportunities -- 1 por (course_id, shift, scholarship_type, concurrency_type)
    --    concurrency_type derivado de TP_MODALIDADE:
    --      AMPLA -> 'AMPLA'
    --      PPI   -> 'COTA_PPI'
    --      PCD   -> 'COTA_PCD'
    --    cutoff_score = NU_NOTA_CORTE (por modalidade)
    WITH mapped_raw AS (
      SELECT
        c.id AS course_id,
        v_semester AS semester,
        CASE WHEN COALESCE(r."NO_TURNO", r."CO_TURNO") ILIKE 'Curso a dist%' THEN 'EaD'
             ELSE COALESCE(r."NO_TURNO", r."CO_TURNO") END AS shift,
        r."DS_TIPO_BOLSA" AS scholarship_type,
        v_year AS year,
        'prouni'::text AS opportunity_type,
        CASE UPPER(TRIM(COALESCE(r."TP_MODALIDADE", '')))
          WHEN 'AMPLA' THEN 'AMPLA'
          WHEN 'PPI'   THEN 'COTA_PPI'
          WHEN 'PCD'   THEN 'COTA_PCD'
          ELSE 'AMPLA'  -- fallback seguro para dados legados
        END AS concurrency_type,
        (SELECT ctr.tags FROM public.concurrency_tag_rules ctr
         WHERE ctr.type_name = CASE UPPER(TRIM(COALESCE(r."TP_MODALIDADE", '')))
           WHEN 'AMPLA' THEN 'AMPLA'
           WHEN 'PPI'   THEN 'COTA_PPI'
           WHEN 'PCD'   THEN 'COTA_PCD'
           ELSE 'AMPLA'
         END LIMIT 1) AS concurrency_tags,
        NULLIF(TRIM(COALESCE(r."NU_NOTA_CORTE", '')), '')::numeric AS cutoff_score,
        (to_jsonb(r) - '_src_ctid') AS raw_data
      FROM temp_batch r
      JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CO_CURSO"::text
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, year, semester, shift, scholarship_type, concurrency_type)
        course_id, semester, shift, scholarship_type, year, opportunity_type,
        concurrency_type, concurrency_tags, cutoff_score, raw_data
      FROM mapped_raw
      ORDER BY course_id, year, semester, shift, scholarship_type, concurrency_type,
               cutoff_score DESC NULLS LAST
    ),
    updated AS (
      UPDATE public.opportunities o
      SET cutoff_score     = m.cutoff_score,
          raw_data         = m.raw_data,
          scholarship_type = m.scholarship_type,
          concurrency_tags = m.concurrency_tags,
          updated_at       = now()
      FROM mapped m
      WHERE o.course_id        = m.course_id
        AND o.opportunity_type = m.opportunity_type
        AND o.year             = m.year
        AND o.semester         = m.semester
        AND o.shift            = m.shift
        AND o.scholarship_type IS NOT DISTINCT FROM m.scholarship_type
        AND o.concurrency_type = m.concurrency_type
      RETURNING o.id
    ),
    inserted AS (
      INSERT INTO public.opportunities (
        course_id, semester, shift, scholarship_type, year, opportunity_type,
        concurrency_type, concurrency_tags, cutoff_score, raw_data
      )
      SELECT m.course_id, m.semester, m.shift, m.scholarship_type, m.year, m.opportunity_type,
             m.concurrency_type, m.concurrency_tags, m.cutoff_score, m.raw_data
      FROM mapped m
      WHERE NOT EXISTS (
        SELECT 1 FROM public.opportunities o
        WHERE o.course_id        = m.course_id
          AND o.opportunity_type = m.opportunity_type
          AND o.year             = m.year
          AND o.semester         = m.semester
          AND o.shift            = m.shift
          AND o.scholarship_type IS NOT DISTINCT FROM m.scholarship_type
          AND o.concurrency_type = m.concurrency_type
      )
      -- FIX: inferencia pelo indice unico PARCIAL (nao e uma CONSTRAINT nomeada).
      ON CONFLICT (course_id, opportunity_type, year, semester, shift, scholarship_type, concurrency_type)
        WHERE opportunity_type = 'prouni' AND concurrency_type IS NOT NULL
      DO NOTHING
      RETURNING id
    )
    SELECT count(*) INTO v_total_processed_in_log FROM inserted;

    -- 5. ProUni Vacancies -- 1 por oportunidade (concurrency_type ja esta na opp)
    --    qt_ofertada = "Bolsas Ofertadas" (total da modalidade neste curso)
    --    qt_ocupada  = "Bolsas Ocupadas"
    WITH vacancies_agg AS (
      SELECT
        o.id AS opportunity_id,
        MAX(COALESCE(NULLIF(TRIM(r."Bolsas Ofertadas"::text), ''), '0')::integer) AS qt_ofertada,
        MAX(COALESCE(NULLIF(TRIM(r."Bolsas Ocupadas"::text),  ''), '0')::integer) AS qt_ocupada
      FROM temp_batch r
      JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CO_CURSO"::text
      JOIN public.opportunities o ON o.course_id = c.id
        AND o.opportunity_type = 'prouni'
        AND o.year             = v_year
        AND o.semester         = v_semester
        AND o.shift            = CASE WHEN COALESCE(r."NO_TURNO", r."CO_TURNO") ILIKE 'Curso a dist%' THEN 'EaD'
                                      ELSE COALESCE(r."NO_TURNO", r."CO_TURNO") END
        AND o.scholarship_type = r."DS_TIPO_BOLSA"
        AND o.concurrency_type = CASE UPPER(TRIM(COALESCE(r."TP_MODALIDADE", '')))
                                    WHEN 'AMPLA' THEN 'AMPLA'
                                    WHEN 'PPI'   THEN 'COTA_PPI'
                                    WHEN 'PCD'   THEN 'COTA_PCD'
                                    ELSE 'AMPLA'
                                  END
      GROUP BY o.id
    )
    INSERT INTO public.opportunities_prouni_vacancies (
      opportunity_id, qt_ofertada, qt_ocupada
    )
    SELECT va.opportunity_id, va.qt_ofertada, va.qt_ocupada
    FROM vacancies_agg va
    ON CONFLICT (opportunity_id)
    DO UPDATE SET
      qt_ofertada = EXCLUDED.qt_ofertada,
      qt_ocupada  = EXCLUDED.qt_ocupada,
      updated_at  = now();

    v_processed := v_batch_rows;

  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_batch_rows >= p_limit THEN v_has_more := TRUE; END IF;
  IF v_batch_rows = 0 THEN v_has_more := FALSE; END IF;

  UPDATE public.etl_run_logs
  SET records_processed = COALESCE(records_processed, 0) + v_processed
  WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    BEGIN
      -- FIX: JSON valido (antes: '[[\"BOLSA_INTEGRAL\"]]' -> invalid input syntax for type json)
      UPDATE public.opportunities
      SET scholarship_tags = '[["BOLSA_INTEGRAL"]]'::jsonb
      WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester
        AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0)
        AND (UPPER(scholarship_type) LIKE '%INTEGRAL%' OR UPPER(scholarship_type) = 'BOLSA INTEGRAL');

      UPDATE public.opportunities
      SET scholarship_tags = '[["BOLSA_PARCIAL"]]'::jsonb
      WHERE opportunity_type = 'prouni' AND year = v_year AND semester = v_semester
        AND (scholarship_tags IS NULL OR scholarship_tags::text = 'null' OR jsonb_array_length(scholarship_tags) = 0)
        AND (UPPER(scholarship_type) LIKE '%PARCIAL%' OR UPPER(scholarship_type) LIKE '%50%' OR UPPER(scholarship_type) = 'BOLSA PARCIAL 50%');
    EXCEPTION WHEN OTHERS THEN
      v_errors := COALESCE(v_errors || ' | ', '') || 'scholarship_tags: ' || SQLERRM;
    END;

    -- Metricas de resumo
    SELECT COUNT(DISTINCT "CO_IES")    INTO v_inst_count   FROM public.rawprouni WHERE "CO_IES"    IS NOT NULL;
    SELECT COUNT(DISTINCT "CO_CAMPUS") INTO v_campus_count FROM public.rawprouni WHERE "CO_CAMPUS" IS NOT NULL;
    SELECT COUNT(DISTINCT "CO_CURSO")  INTO v_course_count FROM public.rawprouni WHERE "CO_CURSO"  IS NOT NULL;

    SELECT COUNT(*) INTO v_opp_count
    FROM public.opportunities
    WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';

    SELECT COUNT(*) INTO v_opp_integral
    FROM public.opportunities
    WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni'
      AND scholarship_tags::text LIKE '%BOLSA_INTEGRAL%';

    SELECT COUNT(*) INTO v_opp_parcial
    FROM public.opportunities
    WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni'
      AND scholarship_tags::text LIKE '%BOLSA_PARCIAL%';

    SELECT COUNT(*) INTO v_opp_ampla
    FROM public.opportunities
    WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni'
      AND concurrency_type = 'AMPLA';

    SELECT COUNT(*) INTO v_opp_cota
    FROM public.opportunities
    WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni'
      AND concurrency_type IN ('COTA', 'COTA_PPI', 'COTA_PCD');

    SELECT COUNT(*) INTO v_vacancies_count
    FROM public.opportunities_prouni_vacancies pv
    JOIN public.opportunities o ON o.id = pv.opportunity_id
    WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni';

    SELECT
      COALESCE(SUM(pv.qt_ofertada), 0),
      COALESCE(SUM(pv.qt_ocupada),  0)
    INTO v_total_ofertada, v_total_ocupada
    FROM public.opportunities_prouni_vacancies pv
    JOIN public.opportunities o ON o.id = pv.opportunity_id
    WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni';

    IF v_errors IS NULL THEN
      v_detail_msg := 'ProUni importado com sucesso (concurrency_type por linha).' || chr(10)
        || '- Linhas no arquivo raw:          ' || v_raw_count    || chr(10)
        || '- IES distintas:                  ' || v_inst_count   || chr(10)
        || '- Campus distintos:               ' || v_campus_count || chr(10)
        || '- Cursos distintos:               ' || v_course_count || chr(10)
        || '- Oportunidades no ciclo:         ' || v_opp_count    || chr(10)
        || '- Bolsas integrais:               ' || v_opp_integral || chr(10)
        || '- Bolsas parciais:                ' || v_opp_parcial  || chr(10)
        || '- Opps. AMPLA:                    ' || v_opp_ampla    || chr(10)
        || '- Opps. COTA (PPI+PCD+legado):    ' || v_opp_cota     || chr(10)
        || '- Registros vagas ProUni:         ' || v_vacancies_count || chr(10)
        || '- Total bolsas ofertadas:         ' || v_total_ofertada  || chr(10)
        || '- Total bolsas ocupadas:          ' || v_total_ocupada;

      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      UPDATE public.programs SET is_fully_imported = true WHERE id = p_program_id;
      TRUNCATE TABLE public.rawprouni;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  ELSIF v_errors IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    v_has_more := FALSE;
  END IF;

  RETURN jsonb_build_object(
    'processed',    v_processed,
    'has_more',     v_has_more,
    'log_id',       v_log_id,
    'next_cursor',  v_next_ctid::text,
    'total_raw_rows', v_raw_count,
    'status',       CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'errors',       v_errors
  );

EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_prouni(uuid, integer, text, uuid) TO service_role, authenticated;


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
        scholarship_tags, is_nubo_pick, concurrency_tags
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
        so.is_nubo_pick,
        so.concurrency_tags
      FROM source_opps so
      -- FIX: inferencia pelo indice unico PARCIAL (nao e uma CONSTRAINT nomeada).
      ON CONFLICT (course_id, opportunity_type, year, semester, shift, scholarship_type, concurrency_type)
        WHERE opportunity_type = 'prouni' AND concurrency_type IS NOT NULL
      DO NOTHING
      RETURNING id, course_id, shift, scholarship_type, concurrency_type
    )
    SELECT COUNT(*) INTO v_opp_cloned FROM cloned_opps;

    -- 2. Clone opportunities_prouni_vacancies via chaves naturais
    WITH source_opps AS (
      SELECT id AS src_opp_id, course_id, shift, scholarship_type, concurrency_type
      FROM public.opportunities
      WHERE opportunity_type = 'prouni'
        AND year = v_src_year
        AND semester = v_src_semester
    ),
    new_opps AS (
      SELECT id AS new_opp_id, course_id, shift, scholarship_type, concurrency_type
      FROM public.opportunities
      WHERE opportunity_type = 'prouni'
        AND year = v_tgt_year
        AND semester = v_tgt_semester
    ),
    cloned_vacs AS (
      INSERT INTO public.opportunities_prouni_vacancies (
        opportunity_id,
        qt_ofertada, qt_ocupada
      )
      SELECT
        no.new_opp_id,
        pv.qt_ofertada,
        pv.qt_ocupada
      FROM public.opportunities_prouni_vacancies pv
      JOIN source_opps so ON so.src_opp_id = pv.opportunity_id
      JOIN new_opps no ON
            no.course_id = so.course_id
        AND no.shift = so.shift
        AND no.scholarship_type IS NOT DISTINCT FROM so.scholarship_type
        AND no.concurrency_type = so.concurrency_type
      ON CONFLICT (opportunity_id) DO NOTHING
      RETURNING opportunity_id
    )
    SELECT COUNT(*) INTO v_vac_cloned FROM cloned_vacs;

  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF v_errors IS NULL THEN
    v_detail_msg := 'Ciclo ProUni clonado com sucesso.' || chr(10)
      || '- Origem: ' || v_src_year || '.' || v_src_semester || chr(10)
      || '- Destino: ' || v_tgt_year || '.' || v_tgt_semester || chr(10)
      || '- Oportunidades clonadas: ' || v_opp_cloned || chr(10)
      || '- Vagas clonadas: ' || v_vac_cloned;

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
