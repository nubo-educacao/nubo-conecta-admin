-- 20260829140000_fix_prouni_vacancies_numeric_parse.sql
-- Correcao do parsing numerico das bolsas ProUni no ETL.
--
-- BUG -- "invalid input syntax for type integer: \"1.100\""
--   O CSV do MEC traz "Bolsas Ofertadas"/"Bolsas Ocupadas" como texto com separador
--   de milhar pt-BR ("1.100" = 1100). O cast direto ::integer estoura nessas linhas
--   e derruba o lote inteiro (o erro e capturado pelo EXCEPTION do bloco e o run
--   termina com status 'error' e 0 registros).
--   Em prod: 278.340 linhas no rawprouni, 6 delas com ponto em "Bolsas Ocupadas".
--
--   Correcao: normalizar via regexp_replace(..., '[^0-9]', '', 'g') antes do cast,
--   que tambem absorve espacos e NBSP. Mesmo tratamento ja usado no ramo SiSU
--   (replace(sv.qt_vagas_ofertadas, '.', '')::integer em v_unified_opportunities).
--
--   NU_NOTA_CORTE nao precisa do mesmo tratamento: usa ponto DECIMAL ("614.14") e
--   nao ha nenhum valor com virgula ou nao numerico no raw (verificado em prod).
--
-- Mantem tudo o mais de 20260829120000 (inferencia do indice unico parcial no
-- ON CONFLICT e scholarship_tags com JSON valido). Assinatura preservada.

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
        -- FIX: separador de milhar pt-BR ("1.100") quebrava o cast ::integer.
        MAX(COALESCE(NULLIF(regexp_replace(COALESCE(r."Bolsas Ofertadas"::text, ''), '[^0-9]', '', 'g'), '')::integer, 0)) AS qt_ofertada,
        MAX(COALESCE(NULLIF(regexp_replace(COALESCE(r."Bolsas Ocupadas"::text,  ''), '[^0-9]', '', 'g'), '')::integer, 0)) AS qt_ocupada
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
