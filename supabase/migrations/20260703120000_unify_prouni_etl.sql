-- 20260703120000_unify_prouni_etl.sql
-- Unifies the Prouni ETL pipeline into a single rawprouni staging table
-- and replaces the 3-step pipeline (base + vacancies + occupied) with a single function.
-- Also migrates from courses_prouni_vacancies → opportunities_prouni_vacancies (1:1 with opportunities).

-- ====================================================================================
-- 1. Drop legacy raw tables and recreate rawprouni with the unified 24-column schema
-- ====================================================================================

DROP TABLE IF EXISTS public.rawprounivacancies CASCADE;
DROP TABLE IF EXISTS public.rawprouniocuppied CASCADE;
DROP TABLE IF EXISTS public.rawprouni CASCADE;

CREATE TABLE public.rawprouni (
  "NU_ANO"                TEXT,
  "NU_SEMESTRE"           TEXT,
  "CO_IES"                TEXT,
  "NO_IES"                TEXT,
  "CO_CAMPUS"             TEXT,
  "NO_CAMPUS"             TEXT,
  "CO_CURSO"              TEXT,
  "NO_CURSO"              TEXT,
  "CO_TURNO"              TEXT,
  "NO_TURNO"              TEXT,
  "CO_TIPO_BOLSA"         TEXT,
  "DS_TIPO_BOLSA"         TEXT,
  "MODALIDADE_DO_CURSO"   TEXT,
  "TP_MODALIDADE"         TEXT,
  "NU_NOTA_CORTE"         TEXT,
  "NO_GRAU"               TEXT,
  "NO_MUNICIPIO_CAMPUS"   TEXT,
  "SG_UF_CAMPUS"          TEXT,
  "Bolsas Ofertadas"      TEXT,
  "Bolsas Ocupadas"       TEXT,
  "BOLSAS_AMPLA_OFERTADA" TEXT,
  "BOLSAS_COTA_OFERTADA"  TEXT,
  "BOLSAS_AMPLA_OCUPADA"  TEXT,
  "BOLSAS_COTA_OCUPADA"   TEXT
);

GRANT ALL ON public.rawprouni TO service_role;
GRANT ALL ON public.rawprouni TO authenticated;

-- ====================================================================================
-- 2. Drop legacy courses_prouni_vacancies and create opportunities_prouni_vacancies
-- ====================================================================================

DROP TABLE IF EXISTS public.courses_prouni_vacancies CASCADE;

CREATE TABLE public.opportunities_prouni_vacancies (
  opportunity_id UUID PRIMARY KEY REFERENCES public.opportunities(id) ON DELETE CASCADE,
  bolsas_ampla_ofertada INTEGER DEFAULT 0,
  bolsas_cota_ofertada  INTEGER DEFAULT 0,
  bolsas_ampla_ocupada  INTEGER DEFAULT 0,
  bolsas_cota_ocupada   INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

GRANT ALL ON public.opportunities_prouni_vacancies TO service_role;
GRANT ALL ON public.opportunities_prouni_vacancies TO authenticated;

-- ====================================================================================
-- 3. Drop ALL legacy Prouni ETL functions
-- ====================================================================================

DROP FUNCTION IF EXISTS public.etl_import_prouni(uuid, integer, integer, uuid) CASCADE;
DROP FUNCTION IF EXISTS public.etl_import_prouni_base(uuid) CASCADE;
DROP FUNCTION IF EXISTS public.etl_import_prouni_base(uuid, integer, integer, uuid) CASCADE;
DROP FUNCTION IF EXISTS public.etl_import_prouni_vacancies(uuid) CASCADE;
DROP FUNCTION IF EXISTS public.etl_import_prouni_vacancies(uuid, integer, integer, uuid) CASCADE;
DROP FUNCTION IF EXISTS public.etl_import_prouni_occupied(uuid) CASCADE;
DROP FUNCTION IF EXISTS public.etl_import_prouni_occupied(uuid, integer, integer, uuid) CASCADE;

-- ====================================================================================
-- 4. New unified etl_import_prouni
--    Reads from the unified rawprouni table (24 columns).
--    Creates: institutions, campus, courses, opportunities, opportunities_prouni_vacancies
--    in a single pass.
-- ====================================================================================

CREATE OR REPLACE FUNCTION public.etl_import_prouni(
  p_program_id uuid,
  p_limit integer DEFAULT NULL,
  p_offset integer DEFAULT 0,
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
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawprouni;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'prouni_base', 'running', now(), 0)
    RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  BEGIN
    -- 1. Institutions
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT ON (r."CO_IES"::text) r."CO_IES"::text, r."NO_IES"
    FROM (SELECT * FROM public.rawprouni
          ORDER BY "CO_IES", "CO_CAMPUS", "CO_CURSO", "CO_TURNO", "DS_TIPO_BOLSA"
          LIMIT p_limit OFFSET p_offset) r
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
    FROM (SELECT * FROM public.rawprouni
          ORDER BY "CO_IES", "CO_CAMPUS", "CO_CURSO", "CO_TURNO", "DS_TIPO_BOLSA"
          LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = r."CO_IES"::text
    WHERE r."CO_CAMPUS" IS NOT NULL
    ORDER BY r."CO_CAMPUS"::text, r."NO_CAMPUS"
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name, city = EXCLUDED.city, state = EXCLUDED.state;

    -- 3. Courses
    INSERT INTO public.courses (campus_id, course_code, course_name)
    SELECT DISTINCT ON (ca.id, r."CO_CURSO"::text) ca.id, r."CO_CURSO"::text, r."NO_CURSO"
    FROM (SELECT * FROM public.rawprouni
          ORDER BY "CO_IES", "CO_CAMPUS", "CO_CURSO", "CO_TURNO", "DS_TIPO_BOLSA"
          LIMIT p_limit OFFSET p_offset) r
    JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
    WHERE r."CO_CURSO" IS NOT NULL
    ORDER BY ca.id, r."CO_CURSO"::text, r."NO_CURSO"
    ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name;

    -- 4. Opportunities (one per course+shift, using the unique index uq_opportunities_no_modality)
    --    We pick the highest cutoff score per (course, shift) combination.
    WITH batched_raw AS (
      SELECT * FROM public.rawprouni
      ORDER BY "CO_IES", "CO_CAMPUS", "CO_CURSO", "CO_TURNO", "DS_TIPO_BOLSA"
      LIMIT p_limit OFFSET p_offset
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
        to_jsonb(r) AS raw_data
      FROM batched_raw r
      JOIN public.campus ca ON ca.external_code = r."CO_CAMPUS"::text
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = r."CO_CURSO"::text
    ),
    -- Deduplicate: one opportunity per (course_id, shift), keeping highest cutoff
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
    SELECT (SELECT count(*) FROM batched_raw) INTO v_batch_rows;

    -- 5. ProUni Vacancies (one per opportunity, aggregating AMPLA + COTA from the raw rows)
    --    Each raw row maps to a specific opportunity via (course_id, shift).
    --    We aggregate bolsas at the opportunity level.
    WITH batched_raw AS (
      SELECT * FROM public.rawprouni
      ORDER BY "CO_IES", "CO_CAMPUS", "CO_CURSO", "CO_TURNO", "DS_TIPO_BOLSA"
      LIMIT p_limit OFFSET p_offset
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
  IF p_limit IS NOT NULL AND v_batch_rows >= p_limit THEN v_has_more := TRUE; END IF;
  IF v_batch_rows = 0 THEN v_has_more := FALSE; END IF;

  UPDATE public.etl_run_logs
  SET records_processed = COALESCE(records_processed, 0) + v_processed
  WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  -- Final pass: scholarship tags + stats + truncate
  IF NOT v_has_more THEN
    -- Tag scholarship types
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

    -- Gather stats
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

      -- Mark program as fully imported
      UPDATE public.programs SET is_fully_imported = true WHERE id = p_program_id;

      TRUNCATE TABLE public.rawprouni;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'has_more', v_has_more,
    'log_id', v_log_id,
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

GRANT EXECUTE ON FUNCTION public.etl_import_prouni(uuid, integer, integer, uuid) TO service_role, authenticated;

-- ====================================================================================
-- 5. New function: etl_clone_prouni_cycle
--    Clones opportunities + opportunities_prouni_vacancies from one program cycle to another.
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
  -- Read source cycle
  SELECT cycle_year, cycle_semester INTO v_src_year, v_src_semester
  FROM public.programs WHERE id = p_source_program_id;
  IF v_src_year IS NULL THEN RAISE EXCEPTION 'Source program not found'; END IF;

  -- Read target cycle
  SELECT cycle_year, cycle_semester INTO v_tgt_year, v_tgt_semester
  FROM public.programs WHERE id = p_target_program_id;
  IF v_tgt_year IS NULL THEN RAISE EXCEPTION 'Target program not found'; END IF;

  -- Create log entry
  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
  VALUES (p_target_program_id, 'prouni_clone', 'running', now(), 0)
  RETURNING id INTO v_log_id;

  BEGIN
    -- 1. Clone opportunities (map old id → new id)
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
      RETURNING id, course_id, shift
    )
    SELECT COUNT(*) INTO v_opp_cloned FROM cloned_opps;

    -- 2. Clone opportunities_prouni_vacancies by matching source opp → new opp via (course_id, shift)
    WITH source_opps AS (
      SELECT id AS src_opp_id, course_id, shift
      FROM public.opportunities
      WHERE opportunity_type = 'prouni'
        AND year = v_src_year
        AND semester = v_src_semester
    ),
    new_opps AS (
      SELECT id AS new_opp_id, course_id, shift
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
      JOIN new_opps no ON no.course_id = so.course_id AND no.shift = so.shift
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

    -- Mark target as fully imported
    UPDATE public.programs SET is_fully_imported = true WHERE id = p_target_program_id;

    -- Set prev_program_id on target
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
-- 6. Create program for ProUni 2026.2
-- ====================================================================================

INSERT INTO public.programs (title, type, cycle_year, cycle_semester, status)
VALUES ('ProUni 2026.2', 'prouni', 2026, '2', 'incoming')
ON CONFLICT DO NOTHING;

-- ====================================================================================
-- 7. Update v_unified_opportunities to use opportunities_prouni_vacancies
-- ====================================================================================

DROP MATERIALIZED VIEW IF EXISTS public.mv_course_catalog CASCADE;
DROP VIEW IF EXISTS public.v_unified_institutions CASCADE;
DROP FUNCTION IF EXISTS public.get_unified_opportunities_by_distance(double precision, double precision) CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.v_unified_opportunities CASCADE;

CREATE MATERIALIZED VIEW public.v_unified_opportunities AS

-- ─────────── SISU ───────────
SELECT sisu_branch.* FROM (
  SELECT DISTINCT ON (c.id)
    ('mec_'::text || (c.id)::text) AS unified_id,
    c.course_name                  AS title,
    i.name                         AS provider_name,
    'sisu'::text                   AS type,
    'sisu'::text                   AS opportunity_type,
    'public_universities'::text    AS category,
    false                          AS is_partner,
    ((cp.city || ', '::text) || cp.state) AS location,
    (jsonb_build_array(o.shift) - 'null'::text) AS badges,
    o.created_at,
    NULL::text     AS external_redirect_url,
    false          AS external_redirect_enabled,
    p.status::text AS status,
    id_dates.start_date AS starts_at,
    id_dates.end_date   AS ends_at,
    NULL::numeric  AS match_score,
    NULL::text     AS institution_cover_url,
    sv_curr.nu_vagas_autorizadas,
    i.id           AS institution_id,
    ie.igc         AS institution_igc,
    ie.academic_organization  AS institution_organization,
    ie.administrative_category AS institution_category,
    ie.site        AS institution_site,
    NULL::jsonb    AS eligibility_criteria,
    NULL::jsonb    AS benefits,
    NULL::text     AS brand_color,
    jsonb_build_object(
      'redacao',    sv_curr.peso_redacao,
      'matematica', sv_curr.peso_matematica,
      'linguagens', sv_curr.peso_linguagens,
      'humanas',    sv_curr.peso_ciencias_humanas,
      'natureza',   sv_curr.peso_ciencias_natureza
    ) AS weights,
    sis.acronym    AS institution_acronym,
    cp.latitude,
    cp.longitude,
    s_curr.min_cutoff AS min_cutoff_score_current,
    s_prev.min_cutoff AS min_cutoff_score_prev,
    s_curr.max_cutoff AS max_cutoff_score_current,
    s_prev.max_cutoff AS max_cutoff_score_prev,
    sv_curr.qt_vagas_ofertadas AS qt_vagas_ofertadas_current,
    sv_prev.qt_vagas_ofertadas AS qt_vagas_ofertadas_prev,
    sv_curr.qt_inscricao       AS qt_inscricao_current,
    sv_prev_inscricao.qt_inscricao AS qt_inscricao_prev,
    sv_curr.nu_media_minima_enem AS nu_media_minima_enem_current,
    sv_prev.nu_media_minima_enem AS nu_media_minima_enem_prev,
    vc_curr.has_vagas_ociosas  AS vagas_ociosas_current,
    vc_prev.has_vagas_ociosas  AS vagas_ociosas_prev

  FROM public.opportunities o
    JOIN public.programs p ON p.type = 'sisu' AND p.status <> 'inactive'
    JOIN public.courses c      ON c.id = o.course_id
    JOIN public.campus cp      ON cp.id = c.campus_id
    JOIN public.institutions i ON i.id = cp.institution_id

    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'sisu' AND opp.course_id = o.course_id AND opp.year = p.cycle_year
    ) s_curr ON true

    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'sisu' AND opp.course_id = o.course_id AND opp.year = p.cycle_year - 1
    ) s_prev ON true

    LEFT JOIN LATERAL (
      SELECT d.start_date, d.end_date
      FROM public.important_dates d
      WHERE d.type = 'sisu' AND d.controls_opportunity_dates = true
      ORDER BY d.start_date DESC LIMIT 1
    ) id_dates ON true

    LEFT JOIN LATERAL (
      SELECT sv.*
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.year = p.cycle_year AND op.opportunity_type = 'sisu'
      LIMIT 1
    ) sv_curr ON true

    LEFT JOIN LATERAL (
      SELECT sv.qt_vagas_ofertadas, sv.nu_media_minima_enem
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.year = p.cycle_year - 1 AND op.opportunity_type = 'sisu'
      LIMIT 1
    ) sv_prev ON true

    LEFT JOIN LATERAL (
      SELECT sv.qt_inscricao
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.year = p.cycle_year - 1 AND op.opportunity_type = 'sisu'
        AND sv.qt_inscricao IS NOT NULL
      ORDER BY sv.qt_inscricao::integer DESC
      LIMIT 1
    ) sv_prev_inscricao ON true

    LEFT JOIN LATERAL (
      SELECT
        CASE WHEN count(sv.qt_inscricao) = 0 THEN NULL::boolean
             ELSE bool_or(replace(sv.qt_vagas_ofertadas, '.', '')::integer > sv.qt_inscricao::integer)
        END AS has_vagas_ociosas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.opportunity_type = 'sisu' AND op.year = p.cycle_year
        AND sv.qt_inscricao IS NOT NULL AND sv.qt_vagas_ofertadas IS NOT NULL
    ) vc_curr ON true

    LEFT JOIN LATERAL (
      SELECT
        CASE WHEN count(sv.qt_inscricao) = 0 THEN NULL::boolean
             ELSE bool_or(replace(sv.qt_vagas_ofertadas, '.', '')::integer > sv.qt_inscricao::integer)
        END AS has_vagas_ociosas
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities op ON op.id = sv.opportunity_id
      WHERE op.course_id = o.course_id AND op.opportunity_type = 'sisu' AND op.year = p.cycle_year - 1
        AND sv.qt_inscricao IS NOT NULL AND sv.qt_vagas_ofertadas IS NOT NULL
    ) vc_prev ON true

    LEFT JOIN public.institutions_info_emec ie  ON ie.institution_id = i.id
    LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id

  WHERE o.opportunity_type = 'sisu' AND o.year = p.cycle_year AND o.semester = p.cycle_semester
  ORDER BY c.id, o.created_at
) sisu_branch

UNION ALL

-- ─────────── PROUNI ───────────
SELECT prouni_branch.* FROM (
  SELECT DISTINCT ON (c.id)
    ('mec_'::text || (c.id)::text) AS unified_id,
    c.course_name                  AS title,
    i.name                         AS provider_name,
    'prouni'::text                 AS type,
    'prouni'::text                 AS opportunity_type,
    'grants_scholarships'::text    AS category,
    false                          AS is_partner,
    ((cp.city || ', '::text) || cp.state) AS location,
    (jsonb_build_array('100% Gratuito', o.shift) - 'null'::text) AS badges,
    o.created_at,
    NULL::text     AS external_redirect_url,
    false          AS external_redirect_enabled,
    p.status::text AS status,
    id_dates.start_date AS starts_at,
    id_dates.end_date   AS ends_at,
    NULL::numeric  AS match_score,
    NULL::text     AS institution_cover_url,
    NULL::text     AS nu_vagas_autorizadas,
    i.id           AS institution_id,
    ie.igc         AS institution_igc,
    ie.academic_organization  AS institution_organization,
    ie.administrative_category AS institution_category,
    ie.site        AS institution_site,
    NULL::jsonb    AS eligibility_criteria,
    NULL::jsonb    AS benefits,
    NULL::text     AS brand_color,
    NULL::jsonb    AS weights,
    sis.acronym    AS institution_acronym,
    cp.latitude,
    cp.longitude,
    s_curr.min_cutoff AS min_cutoff_score_current,
    s_prev.min_cutoff AS min_cutoff_score_prev,
    s_curr.max_cutoff AS max_cutoff_score_current,
    s_prev.max_cutoff AS max_cutoff_score_prev,
    pv_curr.qt_vagas_ofertadas AS qt_vagas_ofertadas_current,
    pv_prev.qt_vagas_ofertadas AS qt_vagas_ofertadas_prev,
    NULL::text AS qt_inscricao_current,
    NULL::text AS qt_inscricao_prev,
    NULL::numeric AS nu_media_minima_enem_current,
    NULL::numeric AS nu_media_minima_enem_prev,
    (COALESCE(pv_curr.vagas_ociosas, 0) > 0)::boolean AS vagas_ociosas_current,
    (COALESCE(pv_prev.vagas_ociosas, 0) > 0)::boolean AS vagas_ociosas_prev

  FROM public.opportunities o
    JOIN public.programs p ON p.type = 'prouni' AND p.status <> 'inactive'
    JOIN public.courses c      ON c.id = o.course_id
    JOIN public.campus cp      ON cp.id = c.campus_id
    JOIN public.institutions i ON i.id = cp.institution_id

    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'prouni' AND opp.course_id = o.course_id AND opp.year = p.cycle_year
    ) s_curr ON true

    LEFT JOIN LATERAL (
      SELECT min(opp.cutoff_score) AS min_cutoff, max(opp.cutoff_score) AS max_cutoff
      FROM public.opportunities opp
      WHERE opp.opportunity_type = 'prouni' AND opp.course_id = o.course_id AND opp.year = p.cycle_year - 1
    ) s_prev ON true

    LEFT JOIN LATERAL (
      SELECT d.start_date, d.end_date
      FROM public.important_dates d
      WHERE d.type = 'prouni' AND d.controls_opportunity_dates = true
      ORDER BY d.start_date DESC LIMIT 1
    ) id_dates ON true

    -- Vagas ProUni CURRENT: agora join via opportunities_prouni_vacancies 1:1 com opp
    LEFT JOIN LATERAL (
      SELECT
        sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
        sum((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada)) AS vagas_ociosas
      FROM public.opportunities_prouni_vacancies pv
      JOIN public.opportunities opp ON opp.id = pv.opportunity_id
      WHERE opp.course_id = o.course_id AND opp.year = p.cycle_year AND opp.opportunity_type = 'prouni'
    ) pv_curr ON true

    -- Vagas ProUni PREVIOUS
    LEFT JOIN LATERAL (
      SELECT
        sum(pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada)::text AS qt_vagas_ofertadas,
        sum((pv.bolsas_ampla_ofertada + pv.bolsas_cota_ofertada) - (pv.bolsas_ampla_ocupada + pv.bolsas_cota_ocupada)) AS vagas_ociosas
      FROM public.opportunities_prouni_vacancies pv
      JOIN public.opportunities opp ON opp.id = pv.opportunity_id
      WHERE opp.course_id = o.course_id AND opp.year = p.cycle_year - 1 AND opp.opportunity_type = 'prouni'
    ) pv_prev ON true

    LEFT JOIN public.institutions_info_emec ie  ON ie.institution_id = i.id
    LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id

  WHERE o.opportunity_type = 'prouni' AND o.year = p.cycle_year AND o.semester = p.cycle_semester
  ORDER BY c.id, o.created_at
) prouni_branch

UNION ALL

-- ─────────── PARTNERS ───────────
SELECT
  ('partner_'::text || po.id::text) AS unified_id,
  po.name AS title,
  i.name AS provider_name,
  'partner'::text AS type,
  po.opportunity_type,
  COALESCE(po.category, 'educational_programs'::text) AS category,
  true AS is_partner,
  'Nacional'::text AS location,
  COALESCE(po.eligibility_criteria -> 'badges', '[]'::jsonb) AS badges,
  po.created_at,
  po.external_redirect_config ->> 'url' AS external_redirect_url,
  COALESCE((po.external_redirect_config ->> 'enabled')::boolean, false) AS external_redirect_enabled,
  po.status::text AS status,
  po.starts_at,
  po.ends_at,
  NULL::numeric  AS match_score,
  pi.cover_url   AS institution_cover_url,
  NULL::text     AS nu_vagas_autorizadas,
  i.id           AS institution_id,
  ie.igc         AS institution_igc,
  ie.academic_organization  AS institution_organization,
  ie.administrative_category AS institution_category,
  ie.site        AS institution_site,
  po.eligibility_criteria,
  NULL::jsonb    AS benefits,
  pi.brand_color,
  NULL::jsonb    AS weights,
  sis.acronym    AS institution_acronym,
  NULL::double precision AS latitude,
  NULL::double precision AS longitude,
  NULL::numeric  AS min_cutoff_score_current,
  NULL::numeric  AS min_cutoff_score_prev,
  NULL::numeric  AS max_cutoff_score_current,
  NULL::numeric  AS max_cutoff_score_prev,
  NULL::text     AS qt_vagas_ofertadas_current,
  NULL::text     AS qt_vagas_ofertadas_prev,
  NULL::text     AS qt_inscricao_current,
  NULL::text     AS qt_inscricao_prev,
  NULL::numeric  AS nu_media_minima_enem_current,
  NULL::numeric  AS nu_media_minima_enem_prev,
  NULL::boolean  AS vagas_ociosas_current,
  NULL::boolean  AS vagas_ociosas_prev
FROM public.partner_opportunities po
  JOIN public.institutions i ON i.id = po.institution_id
  LEFT JOIN public.partner_institutions pi ON pi.institution_id = i.id
  LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
  LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
WHERE po.status IN ('incoming', 'opened', 'closed');

GRANT SELECT ON public.v_unified_opportunities TO authenticated, anon, service_role;

-- ====================================================================================
-- 8. Recreate dependent views and functions
-- ====================================================================================

-- v_unified_institutions
CREATE OR REPLACE VIEW public.v_unified_institutions AS
SELECT DISTINCT ON (i.id)
  i.id,
  i.name,
  i.external_code,
  sis.acronym,
  ie.igc,
  ie.academic_organization,
  ie.administrative_category,
  ie.site AS website_url,
  pi.cover_url,
  pi.brand_color,
  (pi.institution_id IS NOT NULL) AS is_partner,
  COALESCE(
    (SELECT jsonb_agg(DISTINCT vuo.opportunity_type ORDER BY vuo.opportunity_type)
     FROM public.v_unified_opportunities vuo WHERE vuo.institution_id = i.id),
    '[]'::jsonb
  ) AS opportunity_types,
  COALESCE(
    (SELECT jsonb_agg(DISTINCT vuo.category ORDER BY vuo.category)
     FROM public.v_unified_opportunities vuo WHERE vuo.institution_id = i.id),
    '[]'::jsonb
  ) AS categories
FROM public.institutions i
LEFT JOIN public.institutions_info_emec ie ON ie.institution_id = i.id
LEFT JOIN public.institutions_info_sisu sis ON sis.institution_id = i.id
LEFT JOIN public.partner_institutions pi ON pi.institution_id = i.id
WHERE EXISTS (
  SELECT 1 FROM public.v_unified_opportunities vuo WHERE vuo.institution_id = i.id
);

GRANT SELECT ON public.v_unified_institutions TO authenticated, anon, service_role;

-- mv_course_catalog
CREATE MATERIALIZED VIEW public.mv_course_catalog AS
SELECT DISTINCT ON (c.course_name)
  c.course_name,
  c.course_code
FROM public.courses c
WHERE EXISTS (
  SELECT 1 FROM public.v_unified_opportunities vuo
  WHERE vuo.unified_id = 'mec_' || c.id::text
);

GRANT SELECT ON public.mv_course_catalog TO authenticated, anon, service_role;

-- get_unified_opportunities_by_distance
CREATE OR REPLACE FUNCTION public.get_unified_opportunities_by_distance(
  p_lat double precision,
  p_long double precision
)
RETURNS TABLE (
  unified_id text,
  title text,
  provider_name text,
  type text,
  opportunity_type text,
  category text,
  is_partner boolean,
  location text,
  badges jsonb,
  created_at timestamptz,
  external_redirect_url text,
  external_redirect_enabled boolean,
  status text,
  starts_at timestamptz,
  ends_at timestamptz,
  match_score numeric,
  institution_cover_url text,
  nu_vagas_autorizadas text,
  institution_id uuid,
  institution_igc text,
  institution_organization text,
  institution_category text,
  institution_site text,
  eligibility_criteria jsonb,
  benefits jsonb,
  brand_color text,
  weights jsonb,
  institution_acronym text,
  latitude double precision,
  longitude double precision,
  min_cutoff_score_current numeric,
  min_cutoff_score_prev numeric,
  max_cutoff_score_current numeric,
  max_cutoff_score_prev numeric,
  qt_vagas_ofertadas_current text,
  qt_vagas_ofertadas_prev text,
  qt_inscricao_current text,
  qt_inscricao_prev text,
  nu_media_minima_enem_current numeric,
  nu_media_minima_enem_prev numeric,
  vagas_ociosas_current boolean,
  vagas_ociosas_prev boolean,
  distance_km double precision
)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    v.*,
    CASE
      WHEN v.latitude IS NOT NULL AND v.longitude IS NOT NULL
           AND p_lat IS NOT NULL AND p_long IS NOT NULL THEN
        6371.0 * acos(
          LEAST(1.0, GREATEST(-1.0,
            cos(radians(p_lat)) * cos(radians(v.latitude)) *
            cos(radians(v.longitude) - radians(p_long)) +
            sin(radians(p_lat)) * sin(radians(v.latitude))
          ))
        )
      ELSE NULL
    END AS distance_km
  FROM public.v_unified_opportunities v;
$$;

GRANT EXECUTE ON FUNCTION public.get_unified_opportunities_by_distance(double precision, double precision) TO authenticated, anon, service_role;

-- ====================================================================================
-- 9. Update rollback function for prouni_base (uses opportunities_prouni_vacancies)
-- ====================================================================================

CREATE OR REPLACE FUNCTION public.etl_rollback_log(p_log_id uuid)
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

  -- Counters
  v_opps_before integer := 0;
  v_opps_after integer := 0;
  v_opps_deleted integer := 0;

  v_vacancies_before integer := 0;
  v_vacancies_after integer := 0;
  v_vacancies_deleted integer := 0;

  v_prouni_vac_before integer := 0;
  v_prouni_vac_after integer := 0;
  v_prouni_vac_deleted integer := 0;
  v_prouni_vac_updated integer := 0;
  v_sisu_vac_updated integer := 0;
BEGIN
  -- Increase local statement timeout to 10 minutes to prevent timeouts
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

  v_new_etl_type := 'rollback_' || v_etl_type;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (v_program_id, v_new_etl_type, 'running', now())
  RETURNING id INTO v_new_log_id;

  IF v_program_id IS NOT NULL THEN
    SELECT cycle_year, cycle_semester INTO v_year, v_semester
    FROM public.programs WHERE id = v_program_id;

    -- Reset the program's fully imported status since a step is being reverted
    UPDATE public.programs SET is_fully_imported = false WHERE id = v_program_id;
  END IF;

  BEGIN
    IF v_etl_type = 'sisu_vacancies' THEN
      -- Count before
      SELECT COUNT(*) INTO v_vacancies_before
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities o ON sv.opportunity_id = o.id
      WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';

      SELECT COUNT(*) INTO v_opps_before
      FROM public.opportunities
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

      -- Vagas SiSU is responsible for setup, so rollback deletes BOTH vacancies and opps.
      DELETE FROM public.opportunities_sisu_vacancies sv
      USING public.opportunities o
      WHERE sv.opportunity_id = o.id
        AND o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';

      DELETE FROM public.opportunities
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

      -- Count after
      SELECT COUNT(*) INTO v_vacancies_after
      FROM public.opportunities_sisu_vacancies sv
      JOIN public.opportunities o ON sv.opportunity_id = o.id
      WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';

      SELECT COUNT(*) INTO v_opps_after
      FROM public.opportunities
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

      v_vacancies_deleted := v_vacancies_before - v_vacancies_after;
      v_opps_deleted := v_opps_before - v_opps_after;

      v_detail_msg := 'Rollback de Vagas SiSU concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Registros de vagas removidos: ' || v_vacancies_deleted || E'\n' ||
                      '• Oportunidades (Base) removidas: ' || v_opps_deleted || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

    ELSIF v_etl_type = 'sisu' THEN
      -- Base SiSU only complements Vagas SiSU

      SELECT COUNT(*) INTO v_opps_before
      FROM public.opportunities
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu'
        AND (cutoff_score IS NOT NULL OR raw_data <> '{}'::jsonb);

      UPDATE public.opportunities_sisu_vacancies sv
      SET qt_inscricao = NULL, updated_at = now()
      FROM public.opportunities o
      WHERE sv.opportunity_id = o.id
        AND o.year = v_year
        AND o.semester = v_semester
        AND o.opportunity_type = 'sisu';
      GET DIAGNOSTICS v_sisu_vac_updated = ROW_COUNT;

      DELETE FROM public.opportunities o
      WHERE o.year = v_year
        AND o.semester = v_semester
        AND o.opportunity_type = 'sisu'
        AND NOT EXISTS (
          SELECT 1 FROM public.opportunities_sisu_vacancies sv
          WHERE sv.opportunity_id = o.id
        );
      GET DIAGNOSTICS v_opps_deleted = ROW_COUNT;

      UPDATE public.opportunities
      SET cutoff_score = NULL, raw_data = '{}'::jsonb, updated_at = now()
      WHERE year = v_year
        AND semester = v_semester
        AND opportunity_type = 'sisu'
        AND (cutoff_score IS NOT NULL OR raw_data <> '{}'::jsonb);

      v_detail_msg := 'Rollback de Base SiSU concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Quantidade de inscrições (Sisu Vacancies) anuladas: ' || v_sisu_vac_updated || E'\n' ||
                      '• Oportunidades criadas pelo Base SiSU e excluídas: ' || v_opps_deleted || E'\n' ||
                      '• Oportunidades do Vagas SiSU restauradas ao estado original: ' || v_opps_before || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

    ELSIF v_etl_type = 'prouni_base' OR v_etl_type = 'prouni_clone' THEN
      -- Prouni: delete vacancies (CASCADE from opp FK) then delete opps
      SELECT COUNT(*) INTO v_prouni_vac_before
      FROM public.opportunities_prouni_vacancies pv
      JOIN public.opportunities o ON o.id = pv.opportunity_id
      WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni';

      SELECT COUNT(*) INTO v_opps_before
      FROM public.opportunities
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';

      -- Delete vacancies first
      DELETE FROM public.opportunities_prouni_vacancies pv
      USING public.opportunities o
      WHERE pv.opportunity_id = o.id
        AND o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni';

      -- Delete opps
      DELETE FROM public.opportunities
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';

      SELECT COUNT(*) INTO v_prouni_vac_after
      FROM public.opportunities_prouni_vacancies pv
      JOIN public.opportunities o ON o.id = pv.opportunity_id
      WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'prouni';

      SELECT COUNT(*) INTO v_opps_after
      FROM public.opportunities
      WHERE year = v_year AND semester = v_semester AND opportunity_type = 'prouni';

      v_prouni_vac_deleted := v_prouni_vac_before - v_prouni_vac_after;
      v_opps_deleted := v_opps_before - v_opps_after;

      v_detail_msg := 'Rollback de ProUni concluído com sucesso.' || E'\n' ||
                      '• Ciclo: ' || COALESCE(v_year::text, '?') || '.' || COALESCE(v_semester, '?') || E'\n' ||
                      '• Oportunidades removidas: ' || v_opps_deleted || E'\n' ||
                      '• Registros de vagas removidos: ' || v_prouni_vac_deleted || E'\n' ||
                      '• Log de origem: ' || p_log_id::text;

    ELSIF v_etl_type = 'emec' OR v_etl_type LIKE 'refresh_%' THEN
      RAISE EXCEPTION 'Cannot rollback global or refresh ETL operations';
    ELSE
      RAISE EXCEPTION 'Unknown ETL type for rollback: %', v_etl_type;
    END IF;

    UPDATE public.etl_run_logs
    SET status = 'success',
        records_processed = COALESCE(v_vacancies_deleted, 0) + COALESCE(v_opps_deleted, 0) + COALESCE(v_prouni_vac_deleted, 0) + COALESCE(v_prouni_vac_updated, 0) + COALESCE(v_sisu_vac_updated, 0),
        errors = v_detail_msg,
        finished_at = now()
    WHERE id = v_new_log_id;

    RETURN jsonb_build_object(
      'status', 'success',
      'message', 'Rollback completed successfully.',
      'new_log_id', v_new_log_id
    );
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.etl_run_logs
    SET status = 'error',
        errors = SQLERRM,
        finished_at = now()
    WHERE id = v_new_log_id;

    RAISE EXCEPTION 'Rollback failed: %', SQLERRM;
  END;
END;
$function$;

-- ====================================================================================
-- 10. Refresh the materialized views
-- ====================================================================================
REFRESH MATERIALIZED VIEW public.v_unified_opportunities;
REFRESH MATERIALIZED VIEW public.mv_course_catalog;
