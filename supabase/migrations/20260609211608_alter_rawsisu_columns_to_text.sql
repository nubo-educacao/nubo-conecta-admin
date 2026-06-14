-- Alter rawsisu staging table to support text values with dots for CO_IES, CO_IES_CURSO, and EDICAO
-- and update ETL functions to clean up dots.

-- 1. Alter staging table column types
ALTER TABLE public.rawsisu 
  ALTER COLUMN "EDICAO" TYPE text USING "EDICAO"::text,
  ALTER COLUMN "CO_IES" TYPE text USING "CO_IES"::text,
  ALTER COLUMN "CO_IES_CURSO" TYPE text USING "CO_IES_CURSO"::text;

-- 2. Redefine etl_import_sisu with dots-cleaning logic
CREATE OR REPLACE FUNCTION public.etl_import_sisu(
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
  v_detail_msg        TEXT;
  v_has_more          BOOLEAN := FALSE;
  v_total_processed_in_log INTEGER := 0;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester FROM public.programs WHERE id = p_program_id;
  IF v_year IS NULL THEN RAISE EXCEPTION 'Program not found'; END IF;

  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisu;

  IF p_log_id IS NULL THEN
    INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at, records_processed)
    VALUES (p_program_id, 'sisu', 'running', now(), 0) RETURNING id INTO v_log_id;
  ELSE
    v_log_id := p_log_id;
  END IF;

  BEGIN
    -- 1. Insert institutions using CO_IES (clean dots if any)
    INSERT INTO public.institutions (external_code, name)
    SELECT DISTINCT replace(r."CO_IES", '.', '') as external_code, r."NO_IES" 
    FROM (SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset) r
    WHERE r."CO_IES" IS NOT NULL AND replace(r."CO_IES", '.', '') <> ''
    ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;

    -- 2. Insert campus using unique constraint (institution_id, name, city)
    INSERT INTO public.campus (institution_id, name, city, state, region)
    SELECT DISTINCT i.id, r."NO_CAMPUS", 
      COALESCE(
        (SELECT c.name FROM public.cities c
         WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(r."NO_MUNICIPIO_CAMPUS"))
           AND c.state = r."SG_UF_CAMPUS" LIMIT 1),
        r."NO_MUNICIPIO_CAMPUS"
      ) as city,
      r."SG_UF_CAMPUS",
      r."DS_REGIAO_CAMPUS"
    FROM (SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = replace(r."CO_IES", '.', '')
    WHERE r."NO_CAMPUS" IS NOT NULL
    ON CONFLICT (institution_id, name, city) DO UPDATE SET state = EXCLUDED.state, region = EXCLUDED.region;

    -- 3. Insert courses using (campus_id, course_code) unique constraint
    INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
    SELECT DISTINCT ca.id, replace(r."CO_IES_CURSO", '.', '') as course_code, r."NO_CURSO", r."DS_GRAU"
    FROM (SELECT * FROM public.rawsisu ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" LIMIT p_limit OFFSET p_offset) r
    JOIN public.institutions i ON i.external_code = replace(r."CO_IES", '.', '')
    JOIN public.campus ca ON ca.institution_id = i.id AND ca.name = r."NO_CAMPUS"
    WHERE r."CO_IES_CURSO" IS NOT NULL AND replace(r."CO_IES_CURSO", '.', '') <> ''
    ON CONFLICT (campus_id, course_code) DO UPDATE SET course_name = EXCLUDED.course_name, degree_type = EXCLUDED.degree_type;

    -- 4. Bulk Upsert Opportunities & update Vacancies records
    WITH batched_raw AS (
      SELECT * FROM public.rawsisu 
      ORDER BY "CO_IES", "NO_CAMPUS", "CO_IES_CURSO", "DS_TURNO", "DS_MOD_CONCORRENCIA" 
      LIMIT p_limit OFFSET p_offset
    ),
    mapped_raw AS (
      SELECT 
        c.id AS course_id, 
        v_semester AS semester, 
        r."DS_TURNO" AS shift, 
        r."DS_MOD_CONCORRENCIA" AS concurrency_type,
        (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = r."DS_MOD_CONCORRENCIA" LIMIT 1) AS concurrency_tags,
        v_year AS year, 
        'sisu'::text AS opportunity_type,
        CASE 
          WHEN r."NU_NOTACORTE" IS NULL OR TRIM(r."NU_NOTACORTE") = '' THEN NULL 
          ELSE REPLACE(REPLACE(TRIM(r."NU_NOTACORTE"), '.', ''), ',', '.')::numeric 
        END AS cutoff_score,
        replace(r."QT_INSCRICAO", '.', '') AS qt_inscricao,
        to_jsonb(r) AS raw_data
      FROM batched_raw r
      JOIN public.institutions i ON i.external_code = replace(r."CO_IES", '.', '')
      JOIN public.campus ca ON ca.institution_id = i.id AND ca.name = r."NO_CAMPUS"
      JOIN public.courses c ON c.campus_id = ca.id AND c.course_code = replace(r."CO_IES_CURSO", '.', '')
    ),
    mapped AS (
      SELECT DISTINCT ON (course_id, opportunity_type, year, semester, shift, concurrency_type) * 
      FROM mapped_raw 
      ORDER BY course_id, opportunity_type, year, semester, shift, concurrency_type, cutoff_score DESC
    ),
    upserted AS (
      INSERT INTO public.opportunities (
        course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data
      )
      SELECT course_id, semester, shift, concurrency_type, concurrency_tags, year, opportunity_type, cutoff_score, raw_data
      FROM mapped
      ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type) 
      WHERE concurrency_type IS NOT NULL
      DO UPDATE SET
        cutoff_score = EXCLUDED.cutoff_score,
        concurrency_tags = EXCLUDED.concurrency_tags,
        raw_data = EXCLUDED.raw_data,
        updated_at = now()
      RETURNING id, course_id, shift, concurrency_type
    ),
    updated_vacancies AS (
      UPDATE public.opportunities_sisu_vacancies sv
      SET qt_inscricao = m.qt_inscricao, updated_at = now()
      FROM upserted u
      JOIN mapped m ON m.course_id = u.course_id AND m.shift = u.shift AND m.concurrency_type = u.concurrency_type
      WHERE sv.opportunity_id = u.id AND m.qt_inscricao IS NOT NULL
      RETURNING sv.opportunity_id
    )
    SELECT (SELECT count(*) FROM mapped_raw) INTO v_processed;
  EXCEPTION WHEN OTHERS THEN
    v_errors := SQLERRM;
  END;

  IF p_limit IS NOT NULL AND v_processed = p_limit THEN v_has_more := TRUE; END IF;
  IF v_processed = 0 THEN v_has_more := FALSE; END IF;

  UPDATE public.etl_run_logs SET records_processed = COALESCE(records_processed, 0) + v_processed WHERE id = v_log_id
  RETURNING records_processed INTO v_total_processed_in_log;

  IF NOT v_has_more THEN
    SELECT COUNT(DISTINCT replace("CO_IES", '.', '')) INTO v_inst_count FROM public.rawsisu WHERE "CO_IES" IS NOT NULL;
    SELECT COUNT(DISTINCT (replace("CO_IES", '.', '') || '|' || "NO_CAMPUS")) INTO v_campus_count FROM public.rawsisu WHERE "CO_IES" IS NOT NULL AND "NO_CAMPUS" IS NOT NULL;
    SELECT COUNT(DISTINCT replace("CO_IES_CURSO", '.', '')) INTO v_course_count FROM public.rawsisu WHERE "CO_IES_CURSO" IS NOT NULL;
    SELECT COUNT(*) INTO v_opp_count FROM public.opportunities WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

    IF v_errors IS NULL THEN
      v_detail_msg := 'Sisu importado com sucesso.' || chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count || chr(10) || '• IES distintas no arquivo:       ' || v_inst_count || chr(10) || '• Campus distintos:               ' || v_campus_count || chr(10) || '• Cursos distintos:               ' || v_course_count || chr(10) || '• Oportunidades no ciclo:         ' || v_opp_count;
      UPDATE public.etl_run_logs SET status = 'success', errors = v_detail_msg, finished_at = now() WHERE id = v_log_id;
      TRUNCATE TABLE public.rawsisu;
      
      -- Mark program as fully imported
      UPDATE public.programs SET is_fully_imported = true WHERE id = p_program_id;
    ELSE
      UPDATE public.etl_run_logs SET status = 'error', errors = v_errors, finished_at = now() WHERE id = v_log_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('processed', v_processed, 'has_more', v_has_more, 'log_id', v_log_id, 'total_raw_rows', v_raw_count, 'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END, 'errors', v_errors);
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN UPDATE public.etl_run_logs SET status = 'error', errors = SQLERRM, finished_at = now() WHERE id = v_log_id; END IF;
  RETURN jsonb_build_object('processed', 0, 'has_more', FALSE, 'status', 'error', 'errors', SQLERRM);
END;
$$;


-- 3. Redefine etl_import_sisu_vacancies with dots-cleaning logic
CREATE OR REPLACE FUNCTION public.etl_import_sisu_vacancies(p_program_id uuid)
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
  v_rec               RECORD;
  v_inst_id           UUID;
  v_campus_id         UUID;
  v_course_id         UUID;
  v_opp_id            UUID;
  v_raw_count         INTEGER;
  v_skipped           INTEGER;
  v_vacancies_in_db   INTEGER;
  v_opps_with_vaga    INTEGER;
  v_opps_without_vaga INTEGER;
  v_opps_total        INTEGER;
  v_historical_prop   INTEGER;
  v_detail_msg        TEXT;
BEGIN
  SELECT cycle_year, cycle_semester INTO v_year, v_semester
  FROM public.programs WHERE id = p_program_id;

  IF v_year IS NULL THEN
    RAISE EXCEPTION 'Program not found';
  END IF;

  INSERT INTO public.etl_run_logs (program_id, etl_type, status, started_at)
  VALUES (p_program_id, 'sisu_vacancies', 'running', now())
  RETURNING id INTO v_log_id;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 1: Institutions
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT DISTINCT replace("CO_IES", '.', '') AS external_code, "NO_IES" AS name
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> ''
  LOOP
    BEGIN
      INSERT INTO public.institutions (external_code, name)
      VALUES (v_rec.external_code, v_rec.name)
      ON CONFLICT (external_code) DO UPDATE SET name = EXCLUDED.name;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'IES: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 2: Institutions Info
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT DISTINCT ON (replace("CO_IES", '.', ''))
      replace("CO_IES", '.', '') AS inst_external_code,
      "SG_IES" AS acronym,
      "DS_ORGANIZACAO_ACADEMICA" AS academic_organization,
      "DS_CATEGORIA_ADM" AS administrative_category
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> ''
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.institutions_info_sisu (institution_id, acronym, academic_organization, administrative_category)
        VALUES (v_inst_id, v_rec.acronym, v_rec.academic_organization, v_rec.administrative_category)
        ON CONFLICT (institution_id) DO UPDATE SET
          acronym = EXCLUDED.acronym,
          academic_organization = EXCLUDED.academic_organization,
          administrative_category = EXCLUDED.administrative_category,
          updated_at = now();
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Info: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 3: Campus
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT DISTINCT
      replace("CO_IES", '.', '') AS inst_external_code,
      "NO_CAMPUS" AS name,
      "NO_MUNICIPIO_CAMPUS" AS municipio,
      "SG_UF_CAMPUS" AS state,
      "DS_REGIAO" AS region
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> '' AND "NO_CAMPUS" IS NOT NULL
  LOOP
    BEGIN
      SELECT id INTO v_inst_id FROM public.institutions WHERE external_code = v_rec.inst_external_code;
      IF v_inst_id IS NOT NULL THEN
        INSERT INTO public.campus (institution_id, name, city, state, region)
        VALUES (
          v_inst_id,
          v_rec.name,
          COALESCE(
            (SELECT c.name FROM public.cities c
             WHERE public.f_unaccent(lower(c.name)) = public.f_unaccent(lower(v_rec.municipio))
               AND c.state = v_rec.state LIMIT 1),
            v_rec.municipio
          ),
          v_rec.state,
          v_rec.region
        )
        ON CONFLICT (institution_id, name, city) DO UPDATE SET
          state = EXCLUDED.state,
          region = EXCLUDED.region;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Campus: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 4: Courses
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT DISTINCT
      replace("CO_IES", '.', '') AS inst_external_code,
      "NO_CAMPUS" AS campus_name,
      replace("CO_IES_CURSO", '.', '') AS course_code,
      "NO_CURSO" AS course_name,
      "DS_GRAU" AS degree_type
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> '' 
      AND "NO_CAMPUS" IS NOT NULL 
      AND "CO_IES_CURSO" IS NOT NULL AND replace("CO_IES_CURSO", '.', '') <> ''
  LOOP
    BEGIN
      SELECT ca.id INTO v_campus_id
      FROM public.campus ca
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name = v_rec.campus_name
      LIMIT 1;

      IF v_campus_id IS NOT NULL THEN
        INSERT INTO public.courses (campus_id, course_code, course_name, degree_type)
        VALUES (v_campus_id, v_rec.course_code, v_rec.course_name, v_rec.degree_type)
        ON CONFLICT (campus_id, course_code) DO UPDATE SET
          course_name = EXCLUDED.course_name,
          degree_type = EXCLUDED.degree_type;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Course: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- ─────────────────────────────────────────────────────────────────────────
  -- STEP 5: Opportunities & Vacancies
  -- ─────────────────────────────────────────────────────────────────────────
  FOR v_rec IN
    SELECT
      replace("CO_IES", '.', '')            AS inst_external_code,
      "NO_CAMPUS"               AS campus_name,
      replace("CO_IES_CURSO", '.', '')      AS course_code,
      "DS_TURNO"                AS shift,
      "DS_MOD_CONCORRENCIA"     AS concurrency_type,
      *
    FROM public.rawsisuvacancies
    WHERE "CO_IES" IS NOT NULL AND replace("CO_IES", '.', '') <> '' 
      AND "NO_CAMPUS" IS NOT NULL 
      AND "CO_IES_CURSO" IS NOT NULL AND replace("CO_IES_CURSO", '.', '') <> ''
  LOOP
    BEGIN
      SELECT c.id INTO v_course_id
      FROM public.courses c
      JOIN public.campus ca ON ca.id = c.campus_id
      JOIN public.institutions i ON i.id = ca.institution_id
      WHERE i.external_code = v_rec.inst_external_code
        AND ca.name         = v_rec.campus_name
        AND c.course_code   = v_rec.course_code
      LIMIT 1;

      IF v_course_id IS NOT NULL THEN
        
        -- Create or update Opportunity (Without cutoff_score, as it comes from Base)
        INSERT INTO public.opportunities (
          course_id,
          semester,
          shift,
          concurrency_type,
          concurrency_tags,
          year,
          opportunity_type,
          cutoff_score,
          raw_data
        )
        VALUES (
          v_course_id,
          v_semester,
          v_rec.shift,
          v_rec.concurrency_type,
          (SELECT tags FROM public.concurrency_tag_rules WHERE type_name = v_rec.concurrency_type LIMIT 1),
          v_year,
          'sisu',
          NULL, -- No cutoff score in vacancies file
          '{}'::jsonb
        )
        ON CONFLICT (course_id, opportunity_type, year, semester, shift, concurrency_type)
        WHERE concurrency_type IS NOT NULL
        DO UPDATE SET
          concurrency_tags = EXCLUDED.concurrency_tags,
          updated_at       = now()
        RETURNING id INTO v_opp_id;

        -- Create or update Vacancies
        IF v_opp_id IS NOT NULL THEN
          INSERT INTO public.opportunities_sisu_vacancies (
            opportunity_id,
            qt_semestre, nu_vagas_autorizadas, qt_vagas_ofertadas,
            nu_percentual_bonus, tp_mod_concorrencia, tp_cota, ds_mod_concorrencia,
            peso_redacao, nota_minima_redacao,
            peso_linguagens, nota_minima_linguagens,
            peso_matematica, nota_minima_matematica,
            peso_ciencias_humanas, nota_minima_ciencias_humanas,
            peso_ciencias_natureza, nota_minima_ciencias_natureza,
            nu_media_minima_enem,
            perc_uf_ibge_ppi, perc_uf_ibge_pp, perc_uf_ibge_i, perc_uf_ibge_q, perc_uf_ibge_pcd,
            nu_perc_lei, nu_perc_ppi, nu_perc_pp, nu_perc_i, nu_perc_q, nu_perc_pcd
          )
          VALUES (
            v_opp_id,
            v_rec."QT_SEMESTRE",
            v_rec."NU_VAGAS_AUTORIZADAS",
            v_rec."QT_VAGAS_OFERTADAS",
            v_rec."NU_PERCENTUAL_BONUS",
            v_rec."TP_MOD_CONCORRENCIA",
            v_rec."TP_COTA",
            v_rec."DS_MOD_CONCORRENCIA",
            COALESCE(NULLIF(REPLACE(v_rec."PESO_REDACAO",           ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_REDACAO",    ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."PESO_LINGUAGENS",        ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_LINGUAGENS", ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."PESO_MATEMATICA",        ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_MATEMATICA", ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_HUMANAS",        ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_HUMANAS", ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."PESO_CIENCIAS_NATUREZA",        ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NOTA_MINIMA_CIENCIAS_NATUREZA", ',', '.'), ''), '0')::numeric,
            COALESCE(NULLIF(REPLACE(v_rec."NU_MEDIA_MINIMA_ENEM",  ',', '.'), ''), '0')::numeric,
            v_rec."PERC_UF_IBGE_PPI",
            v_rec."PERC_UF_IBGE_PP",
            v_rec."PERC_UF_IBGE_I",
            v_rec."PERC_UF_IBGE_Q",
            v_rec."PERC_UF_IBGE_PCD",
            v_rec."NU_PERC_LEI",
            v_rec."NU_PERC_PPI",
            v_rec."NU_PERC_PP",
            v_rec."NU_PERC_I",
            v_rec."NU_PERC_Q",
            v_rec."NU_PERC_PCD"
          )
          ON CONFLICT (opportunity_id)
          DO UPDATE SET
            qt_semestre                   = EXCLUDED.qt_semestre,
            nu_vagas_autorizadas          = EXCLUDED.nu_vagas_autorizadas,
            qt_vagas_ofertadas            = EXCLUDED.qt_vagas_ofertadas,
            nu_percentual_bonus           = EXCLUDED.nu_percentual_bonus,
            tp_mod_concorrencia           = EXCLUDED.tp_mod_concorrencia,
            tp_cota                       = EXCLUDED.tp_cota,
            ds_mod_concorrencia           = EXCLUDED.ds_mod_concorrencia,
            peso_redacao                  = EXCLUDED.peso_redacao,
            nota_minima_redacao           = EXCLUDED.nota_minima_redacao,
            peso_linguagens               = EXCLUDED.peso_linguagens,
            nota_minima_linguagens        = EXCLUDED.nota_minima_linguagens,
            peso_matematica               = EXCLUDED.peso_matematica,
            nota_minima_matematica        = EXCLUDED.nota_minima_matematica,
            peso_ciencias_humanas         = EXCLUDED.peso_ciencias_humanas,
            nota_minima_ciencias_humanas  = EXCLUDED.nota_minima_ciencias_humanas,
            peso_ciencias_natureza        = EXCLUDED.peso_ciencias_natureza,
            nota_minima_ciencias_natureza = EXCLUDED.nota_minima_ciencias_natureza,
            nu_media_minima_enem          = EXCLUDED.nu_media_minima_enem,
            updated_at                    = now();

          v_processed := v_processed + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Opp/Vaga: ' || SQLERRM, 1500);
    END;
  END LOOP;

  -- Historical propagation (previous year -> current year)
  BEGIN
    -- cutoff_score
    UPDATE public.opportunities op_curr
    SET cutoff_score = op_prev.cutoff_score
    FROM public.opportunities op_prev
    WHERE op_curr.opportunity_type = 'sisu' AND op_curr.year = v_year AND op_curr.semester = v_semester
      AND op_prev.opportunity_type = 'sisu' AND op_prev.year = v_year - 1 AND op_prev.semester = v_semester
      AND op_curr.course_id        = op_prev.course_id
      AND op_curr.shift            = op_prev.shift
      AND op_curr.concurrency_type = op_prev.concurrency_type
      AND op_prev.cutoff_score IS NOT NULL
      AND op_curr.cutoff_score IS NULL;

    -- historic vacancies
    UPDATE public.opportunities_sisu_vacancies osv_curr
    SET vagas_ociosas_prev      = osv_prev.vagas_ociosas_prev,
        qt_inscricao_prev       = osv_prev.qt_inscricao_prev,
        qt_vagas_ofertadas_prev = osv_prev.qt_vagas_ofertadas
    FROM public.opportunities o_curr
    JOIN public.opportunities o_prev
      ON o_prev.course_id       = o_curr.course_id
     AND o_prev.shift           = o_curr.shift
     AND o_prev.concurrency_type = o_curr.concurrency_type
     AND o_prev.year            = v_year - 1
     AND o_prev.semester        = v_semester
     AND o_prev.opportunity_type = 'sisu'
    JOIN public.opportunities_sisu_vacancies osv_prev ON osv_prev.opportunity_id = o_prev.id
    WHERE osv_curr.opportunity_id = o_curr.id
      AND o_curr.year             = v_year
      AND o_curr.semester         = v_semester
      AND o_curr.opportunity_type = 'sisu';

    GET DIAGNOSTICS v_historical_prop = ROW_COUNT;
  EXCEPTION WHEN OTHERS THEN
    v_historical_prop := 0;
    v_errors := LEFT(COALESCE(v_errors || '; ', '') || 'Propagation: ' || SQLERRM, 1500);
  END;

  -- ── Rich post-run stats ──────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_raw_count FROM public.rawsisuvacancies;
  v_skipped := v_raw_count - v_processed;

  SELECT COUNT(*) INTO v_vacancies_in_db
  FROM public.opportunities_sisu_vacancies osv
  JOIN public.opportunities o ON o.id = osv.opportunity_id
  WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';

  SELECT COUNT(*) INTO v_opps_total
  FROM public.opportunities
  WHERE year = v_year AND semester = v_semester AND opportunity_type = 'sisu';

  SELECT COUNT(DISTINCT o.id) INTO v_opps_with_vaga
  FROM public.opportunities o
  JOIN public.opportunities_sisu_vacancies osv ON osv.opportunity_id = o.id
  WHERE o.year = v_year AND o.semester = v_semester AND o.opportunity_type = 'sisu';

  v_opps_without_vaga := v_opps_total - v_opps_with_vaga;

  IF v_errors IS NULL THEN
    v_detail_msg :=
      'Vagas SiSU importadas com sucesso.' ||
      chr(10) || '• Linhas no arquivo raw:          ' || v_raw_count ||
      chr(10) || '• Vagas vinculadas (mapeadas):    ' || v_processed ||
      chr(10) || '• Linhas ignoradas (s/ opp.):     ' || v_skipped ||
      chr(10) || '• Registros em sisu_vacancies:    ' || v_vacancies_in_db ||
      chr(10) || '• Oportunidades c/ vaga:          ' || v_opps_with_vaga || ' / ' || v_opps_total ||
      chr(10) || '• Oportunidades s/ vaga:          ' || v_opps_without_vaga ||
      chr(10) || '• Vagas c/ histórico propagado:   ' || COALESCE(v_historical_prop, 0);

    UPDATE public.etl_run_logs
    SET status = 'success',
        records_processed = v_processed,
        errors = v_detail_msg,
        finished_at = now()
    WHERE id = v_log_id;
  ELSE
    UPDATE public.etl_run_logs
    SET status = 'error', records_processed = v_processed, errors = v_errors, finished_at = now()
    WHERE id = v_log_id;
  END IF;

  RETURN jsonb_build_object(
    'vacancies_processed', v_processed,
    'vacancies_in_db', v_vacancies_in_db,
    'opps_with_vaga', v_opps_with_vaga,
    'opps_without_vaga', v_opps_without_vaga,
    'historical_propagated', v_historical_prop,
    'status', CASE WHEN v_errors IS NULL THEN 'success' ELSE 'error' END,
    'errors', v_errors
  );
EXCEPTION WHEN OTHERS THEN
  IF v_log_id IS NOT NULL THEN
    UPDATE public.etl_run_logs SET status = 'error', errors = LEFT(SQLERRM, 1500), finished_at = now() WHERE id = v_log_id;
  END IF;
  RETURN jsonb_build_object('processed', 0, 'status', 'error', 'errors', SQLERRM);
END;
$$;
