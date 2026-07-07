-- 20260707140000_normalize_prouni_ead_shift.sql
-- Normaliza o turno EAD do ProUni na ORIGEM (opportunities.shift): o rótulo canônico do
-- sistema é 'EaD' (usado pelo SiSU); o ProUni vinha do MEC como 'Curso a distância'.
-- Com a normalização na tabela base, tudo que consome EAD (match engine, badges da
-- matview — que derivam de o.shift —, lista de opções, filtros) herda automaticamente.
--
-- 1. Deleta 4 opps ProUni com encoding quebrado no shift ('Curso a dist��ncia') — são
--    duplicatas exatas (mesmo course/year/semester/scholarship_type) de linhas normais;
--    vacancies removidas via FK ON DELETE CASCADE.
-- 2. Backfill: 'Curso a distância' -> 'EaD' nas opps ProUni existentes.
-- 3. etl_import_prouni normaliza o shift na importação (criação de opps + JOIN vacancies)
--    — reproduz a função da 20260706120000 com essa única mudança.
-- 4. REFRESH da matview (badges saem 'EaD' automaticamente; definição não muda).

-- ====================================================================================
-- 0a. Remover duplicatas com encoding quebrado
-- ====================================================================================
DELETE FROM public.opportunities
WHERE opportunity_type = 'prouni'
  AND shift LIKE 'Curso a dist%'
  AND shift <> 'Curso a distância';

-- ====================================================================================
-- 0b. Backfill: normalizar o rótulo EAD nas opps ProUni existentes
-- ====================================================================================
UPDATE public.opportunities
SET shift = 'EaD', updated_at = now()
WHERE opportunity_type = 'prouni'
  AND shift = 'Curso a distância';

-- ====================================================================================
-- 1. etl_import_prouni — normalização do shift EAD na importação
-- ====================================================================================
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
  v_opp_with_cutoff   INTEGER;
  v_vacancies_count   INTEGER;
  v_ampla_ofertada    BIGINT;
  v_cota_ofertada     BIGINT;
  v_ampla_ocupada     BIGINT;
  v_cota_ocupada      BIGINT;
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
      RAISE EXCEPTION 'Já existe uma importação ProUni em andamento para este ciclo. Aguarde ou pare a execução atual.';
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

    -- 4. Opportunities — 1 por (curso, turno, TIPO_BOLSA). cutoff_score sempre NULL (Card 2).
    WITH batched_raw AS (
      SELECT * FROM temp_batch
    ),
    mapped_raw AS (
      SELECT
        c.id AS course_id,
        v_semester AS semester,
        CASE WHEN COALESCE(r."NO_TURNO", r."CO_TURNO") ILIKE 'Curso a dist%' THEN 'EaD'
             ELSE COALESCE(r."NO_TURNO", r."CO_TURNO") END AS shift,
        r."DS_TIPO_BOLSA" AS scholarship_type,
        v_year AS year,
        'prouni'::text AS opportunity_type,
        NULL::numeric AS cutoff_score,          -- Card 2: ProUni sem nota de corte
        (to_jsonb(r) - '_src_ctid') AS raw_data
      FROM batched_raw r
      JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CO_CURSO"::text
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, year, semester, shift, scholarship_type)
        course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data
      FROM mapped_raw
      ORDER BY course_id, year, semester, shift, scholarship_type, cutoff_score DESC NULLS LAST
    ),
    updated AS (
      UPDATE public.opportunities o
      SET cutoff_score = m.cutoff_score, raw_data = m.raw_data, scholarship_type = m.scholarship_type, updated_at = now()
      FROM mapped m
      WHERE o.course_id = m.course_id
        AND o.opportunity_type = m.opportunity_type
        AND o.year = m.year
        AND o.semester = m.semester
        AND o.shift = m.shift
        AND o.scholarship_type IS NOT DISTINCT FROM m.scholarship_type   -- grão com tipo de bolsa
        AND o.concurrency_type IS NULL
      RETURNING o.id
    ),
    inserted AS (
      INSERT INTO public.opportunities (course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data)
      SELECT m.course_id, m.semester, m.shift, m.scholarship_type, m.year, m.opportunity_type, m.cutoff_score, m.raw_data
      FROM mapped m
      WHERE NOT EXISTS (
        SELECT 1 FROM public.opportunities o
        WHERE o.course_id = m.course_id
          AND o.opportunity_type = m.opportunity_type
          AND o.year = m.year
          AND o.semester = m.semester
          AND o.shift = m.shift
          AND o.scholarship_type IS NOT DISTINCT FROM m.scholarship_type -- grão com tipo de bolsa
          AND o.concurrency_type IS NULL
      )
      RETURNING id
    )
    SELECT count(*) INTO v_total_processed_in_log FROM inserted;

    -- 5. ProUni Vacancies — casa por (curso, turno, TIPO_BOLSA) para não somar tipos distintos
    WITH batched_raw AS (
      SELECT * FROM temp_batch
    ),
    vacancies_agg AS (
      SELECT
        o.id AS opportunity_id,
        SUM(COALESCE(NULLIF(TRIM(r."BOLSAS_AMPLA_OFERTADA"), ''), '0')::integer) AS bolsas_ampla_ofertada,
        SUM(COALESCE(NULLIF(TRIM(r."BOLSAS_COTA_OFERTADA"), ''), '0')::integer) AS bolsas_cota_ofertada,
        SUM(COALESCE(NULLIF(TRIM(r."BOLSAS_AMPLA_OCUPADA"), ''), '0')::integer) AS bolsas_ampla_ocupada,
        SUM(COALESCE(NULLIF(TRIM(r."BOLSAS_COTA_OCUPADA"), ''), '0')::integer) AS bolsas_cota_ocupada
      FROM batched_raw r
      JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CO_CURSO"::text
      JOIN public.opportunities o ON o.course_id = c.id
        AND o.opportunity_type = 'prouni'
        AND o.year = v_year
        AND o.semester = v_semester
        AND o.shift = CASE WHEN COALESCE(r."NO_TURNO", r."CO_TURNO") ILIKE 'Curso a dist%' THEN 'EaD'
                           ELSE COALESCE(r."NO_TURNO", r."CO_TURNO") END
        AND o.scholarship_type = r."DS_TIPO_BOLSA"    -- grão com tipo de bolsa
        AND o.concurrency_type IS NULL
      GROUP BY o.id
    )
    INSERT INTO public.opportunities_prouni_vacancies (
      opportunity_id,
      bolsas_ampla_ofertada, bolsas_cota_ofertada,
      bolsas_ampla_ocupada, bolsas_cota_ocupada
    )
    SELECT
      va.opportunity_id,
      va.bolsas_ampla_ofertada, va.bolsas_cota_ofertada,
      va.bolsas_ampla_ocupada, va.bolsas_cota_ocupada
    FROM vacancies_agg va
    ON CONFLICT (opportunity_id)
    DO UPDATE SET
      bolsas_ampla_ofertada = EXCLUDED.bolsas_ampla_ofertada,
      bolsas_cota_ofertada = EXCLUDED.bolsas_cota_ofertada,
      bolsas_ampla_ocupada = EXCLUDED.bolsas_ampla_ocupada,
      bolsas_cota_ocupada = EXCLUDED.bolsas_cota_ocupada,
      updated_at = now();

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

    SELECT COUNT(DISTINCT "CO_IES") INTO v_inst_count FROM public.rawprouni WHERE "CO_IES" IS NOT NULL;
    SELECT COUNT(DISTINCT "CO_CAMPUS") INTO v_campus_count FROM public.rawprouni WHERE "CO_CAMPUS" IS NOT NULL;
    SELECT COUNT(DISTINCT "CO_CURSO") INTO v_course_count FROM public.rawprouni WHERE "CO_CURSO" IS NOT NULL;
    SELECT COUNT(*) INTO v_opp_count FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';
    SELECT COUNT(*) INTO v_opp_integral FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND scholarship_tags::text LIKE '%BOLSA_INTEGRAL%';
    SELECT COUNT(*) INTO v_opp_parcial FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND scholarship_tags::text LIKE '%BOLSA_PARCIAL%';
    SELECT COUNT(*) INTO v_opp_with_cutoff FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni' AND cutoff_score IS NOT NULL;
    SELECT COUNT(*) INTO v_vacancies_count
    FROM public.opportunities_prouni_vacancies pv
    JOIN public.opportunities o ON o.id = pv.opportunity_id
    WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni';
    SELECT COALESCE(SUM(pv.bolsas_ampla_ofertada), 0), COALESCE(SUM(pv.bolsas_cota_ofertada), 0),
           COALESCE(SUM(pv.bolsas_ampla_ocupada), 0), COALESCE(SUM(pv.bolsas_cota_ocupada), 0)
    INTO v_ampla_ofertada, v_cota_ofertada, v_ampla_ocupada, v_cota_ocupada
    FROM public.opportunities_prouni_vacancies pv
    JOIN public.opportunities o ON o.id = pv.opportunity_id
    WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni';

    IF v_errors IS NULL THEN
      v_detail_msg := 'ProUni importado com sucesso (pipeline unificado).' || chr(10)
        || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10)
        || '• IES distintas:                  ' || v_inst_count || chr(10)
        || '• Campus distintos:               ' || v_campus_count || chr(10)
        || '• Cursos distintos:               ' || v_course_count || chr(10)
        || '• Oportunidades no ciclo:         ' || v_opp_count || chr(10)
        || '• Bolsas integrais:               ' || v_opp_integral || chr(10)
        || '• Bolsas parciais:                ' || v_opp_parcial || chr(10)
        || '• Opps. com nota de corte:        ' || v_opp_with_cutoff || chr(10)
        || '• Registros vagas ProUni:         ' || v_vacancies_count || chr(10)
        || '• Bolsas ampla ofertada:          ' || v_ampla_ofertada || chr(10)
        || '• Bolsas cota ofertada:           ' || v_cota_ofertada || chr(10)
        || '• Bolsas ampla ocupada:           ' || v_ampla_ocupada || chr(10)
        || '• Bolsas cota ocupada:            ' || v_cota_ocupada;

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
    'processed', v_processed,
    'has_more', v_has_more,
    'log_id', v_log_id,
    'next_cursor', v_next_ctid::text,
    'total_raw_rows', v_raw_count,
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'errors', v_errors
  );

EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_import_prouni(uuid, integer, text, uuid) TO service_role, authenticated;

-- ====================================================================================
-- 2. Refresh da matview — badges derivam de opportunities.shift, então saem 'EaD'
--    automaticamente após o backfill. A definição da matview não muda.
-- ====================================================================================
REFRESH MATERIALIZED VIEW public.v_unified_opportunities;
