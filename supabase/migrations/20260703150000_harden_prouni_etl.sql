-- 20260703150000_harden_prouni_etl.sql
-- Hardening of the unified ProUni ETL pipeline (audit follow-up).
--
-- Fixes:
--   1. etl_rollback_log overload conflict: migration 120000 created a NEW 1-arg
--      overload instead of replacing the batched 3-arg version, leaving the old
--      body (which references the dropped table courses_prouni_vacancies) as the
--      one PostgREST actually calls. We DROP both and recreate a single canonical
--      version aware of opportunities_prouni_vacancies, batched (p_limit/has_more).
--   2. Concurrency: no guard prevented two simultaneous imports (or an import +
--      rollback) on the same cycle, which combined with TRUNCATE rawprouni caused
--      the "lock timeout" seen in production. We add a partial UNIQUE index and an
--      explicit guard, plus a reaper for stale 'running' logs (crashed browsers).
--   3. Performance: OFFSET pagination is O(N^2) over the whole file. Replaced with
--      keyset pagination over ctid (TID Range Scan) — O(1) seek per batch, no
--      schema change to rawprouni, NULL-safe, and stable because rawprouni is
--      read-only between load and truncate.
--   4. Stop determinism: etl_stop_log matched pg_stat_activity by substring of the
--      log id in the query text (fragile under bound parameters). We now record
--      pg_backend_pid() on the log and cancel that pid directly, verifying it is
--      still running an etl_import statement before cancelling (pool-safe).
--   5. Status semantics: user Stop is now a distinct 'cancelled' status instead of
--      being conflated with a real 'error'.

-- ====================================================================================
-- 0. Reap any pre-existing stale 'running' logs so the UNIQUE index below can build.
--    (There may be stuck rows from crashed runs — e.g. the one in the screenshot.)
-- ====================================================================================
UPDATE public.etl_run_logs
SET status = 'error',
    errors = COALESCE(errors, '') || ' [expirado automaticamente durante manutenção do pipeline]',
    finished_at = COALESCE(finished_at, now())
WHERE status = 'running';

-- ====================================================================================
-- 1. Status constraint: allow 'cancelled' (user-initiated Stop, distinct from error)
-- ====================================================================================
ALTER TABLE public.etl_run_logs DROP CONSTRAINT IF EXISTS etl_run_logs_status_check;
ALTER TABLE public.etl_run_logs
  ADD CONSTRAINT etl_run_logs_status_check
  CHECK (status IN ('running', 'success', 'error', 'cancelled'));

-- ====================================================================================
-- 2. backend_pid: the Postgres backend running the current batch, for deterministic
--    cancellation.
-- ====================================================================================
ALTER TABLE public.etl_run_logs ADD COLUMN IF NOT EXISTS backend_pid INTEGER;

-- ====================================================================================
-- 3. Concurrency guard: at most one 'running' log per (program_id, etl_type).
--    NULL program_id (global steps) is intentionally exempt.
-- ====================================================================================
CREATE UNIQUE INDEX IF NOT EXISTS uq_etl_run_logs_one_running
  ON public.etl_run_logs (program_id, etl_type)
  WHERE status = 'running' AND program_id IS NOT NULL;

-- ====================================================================================
-- 4. Reaper for stale 'running' logs (call from a cron, and defensively from imports)
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.etl_reap_stale_runs(p_max_age interval DEFAULT interval '15 minutes')
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reaped integer;
BEGIN
  UPDATE public.etl_run_logs
  SET status = 'error',
      errors = 'Execução expirada (perda de conexão ou navegador fechado durante o processamento).',
      finished_at = now()
  WHERE status = 'running'
    AND started_at < now() - p_max_age;
  GET DIAGNOSTICS v_reaped = ROW_COUNT;
  RETURN v_reaped;
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_reap_stale_runs(interval) TO service_role, authenticated;

-- ====================================================================================
-- 5. Unified ProUni import — keyset pagination + concurrency guard + pid tracking
-- ====================================================================================

-- Drop the previous (uuid, integer, integer, uuid) signature so the new keyset
-- signature (uuid, integer, text, uuid) does not become a stray overload.
DROP FUNCTION IF EXISTS public.etl_import_prouni(uuid, integer, integer, uuid) CASCADE;

CREATE OR REPLACE FUNCTION public.etl_import_prouni(
  p_program_id uuid,
  p_limit integer DEFAULT 5000,
  p_after_ctid text DEFAULT NULL,   -- keyset cursor: last processed rawprouni ctid
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
    -- First batch: reap stale runs, guard against a genuine concurrent import,
    -- then open the log. The partial UNIQUE index is the hard guarantee.
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
    -- Keep backend_pid current so a Stop cancels the batch actually running now.
    UPDATE public.etl_run_logs SET backend_pid = pg_backend_pid() WHERE id = v_log_id;
  END IF;

  BEGIN
    -- Keyset slice: everything physically after the cursor. '(0,0)' precedes all
    -- real rows (offsets are 1-based), giving a single TID-range predicate that is
    -- seek-based regardless of whether a cursor was supplied.
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

    -- 4. Opportunities (one per course+shift; highest cutoff wins within the batch)
    WITH batched_raw AS (
      SELECT * FROM temp_batch
    ),
    mapped_raw AS (
      SELECT
        c.id AS course_id,
        v_semester AS semester,
        COALESCE(r."NO_TURNO", r."CO_TURNO") AS shift,
        r."DS_TIPO_BOLSA" AS scholarship_type,
        v_year AS year,
        'prouni'::text AS opportunity_type,
        CASE
          WHEN r."NU_NOTA_CORTE" IS NULL OR TRIM(r."NU_NOTA_CORTE") = '' THEN NULL
          ELSE REPLACE(REPLACE(TRIM(r."NU_NOTA_CORTE"), '.', ''), ',', '.')::numeric
        END AS cutoff_score,
        -- strip the internal cursor column so it never leaks into raw_data
        (to_jsonb(r) - '_src_ctid') AS raw_data
      FROM batched_raw r
      JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CO_CURSO"::text
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, year, semester, shift)
        course_id, semester, shift, scholarship_type, year, opportunity_type, cutoff_score, raw_data
      FROM mapped_raw
      ORDER BY course_id, year, semester, shift, cutoff_score DESC NULLS LAST
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
          AND o.concurrency_type IS NULL
      )
      RETURNING id
    )
    SELECT count(*) INTO v_total_processed_in_log FROM inserted;  -- force CTE execution

    -- 5. ProUni Vacancies (aggregate AMPLA + COTA per opportunity)
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
        AND o.shift = COALESCE(r."NO_TURNO", r."CO_TURNO")
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

  -- Determine if more batches are needed
  IF v_batch_rows >= p_limit THEN v_has_more := TRUE; END IF;
  IF v_batch_rows = 0 THEN v_has_more := FALSE; END IF;

  UPDATE public.etl_run_logs
  SET records_processed = COALESCE(records_processed, 0) + v_processed
  WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  -- Final pass: scholarship tags + stats + truncate
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
    -- Error mid-run (not final batch): fail the log now instead of looping forever.
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
-- 6. Deterministic Stop — cancel by recorded backend_pid, verified still ours.
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.etl_stop_log(p_log_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pid INTEGER;
  v_cancelled BOOLEAN := FALSE;
BEGIN
  -- 1. Read the backend that was last running this import.
  SELECT backend_pid INTO v_pid FROM public.etl_run_logs WHERE id = p_log_id;

  -- 2. Mark the log as cancelled (distinct from a real error).
  UPDATE public.etl_run_logs
  SET status = 'cancelled', errors = 'Cancelado pelo usuário', finished_at = now()
  WHERE id = p_log_id AND status = 'running';

  -- 3. If we know the pid, cancel it — but only if it is STILL running an
  --    etl_import statement, so we never cancel an unrelated pooled backend.
  IF v_pid IS NOT NULL AND v_pid <> pg_backend_pid() THEN
    IF EXISTS (
      SELECT 1 FROM pg_stat_activity
      WHERE pid = v_pid AND state = 'active' AND query ILIKE '%etl_import_%'
    ) THEN
      PERFORM pg_cancel_backend(v_pid);
      v_cancelled := TRUE;
    END IF;
  END IF;

  -- 4. Fallback for legacy logs without a recorded pid: best-effort query match.
  IF NOT v_cancelled AND v_pid IS NULL THEN
    SELECT pid INTO v_pid
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query ILIKE '%etl_import_%'
      AND query ILIKE '%' || p_log_id::text || '%'
      AND pid <> pg_backend_pid()
    LIMIT 1;
    IF v_pid IS NOT NULL THEN
      PERFORM pg_cancel_backend(v_pid);
      v_cancelled := TRUE;
    END IF;
  END IF;

  RETURN jsonb_build_object('status', 'success', 'pid_cancelled', CASE WHEN v_cancelled THEN v_pid ELSE NULL END);
END;
$$;

GRANT EXECUTE ON FUNCTION public.etl_stop_log(UUID) TO service_role, authenticated;

-- ====================================================================================
-- 7. Canonical, batched rollback aware of opportunities_prouni_vacancies.
--    DROP both stray overloads first (the 1-arg from 120000 and the old 3-arg that
--    still referenced the dropped courses_prouni_vacancies table).
-- ====================================================================================
DROP FUNCTION IF EXISTS public.etl_rollback_log(uuid) CASCADE;
DROP FUNCTION IF EXISTS public.etl_rollback_log(uuid, integer, uuid) CASCADE;

CREATE OR REPLACE FUNCTION public.etl_rollback_log(
  p_log_id uuid,
  p_limit integer DEFAULT 500,
  p_active_rollback_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    IF v_etl_type = 'sisu_vacancies' THEN
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
$$;

GRANT EXECUTE ON FUNCTION public.etl_rollback_log(uuid, integer, uuid) TO service_role, authenticated;
