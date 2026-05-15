-- =============================================================================
-- Migration: ETL RPCs para ProUni Vacancies e SisU Approvals
-- Sprint 8.0
-- =============================================================================

-- ---------------------------------------------------------------------------
-- RPC 1: etl_prouni_vacancies
-- Fonte: JOIN rawprounivacancies2025 + rawprouniocuppied2025
-- Destino: opportunities_prouni_vacancies
-- Matching: CO_CURSO + CO_CAMPUS → courses → opportunities (opportunity_type = 'prouni')
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl_prouni_vacancies()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_processed INTEGER := 0;
  v_errors    JSONB   := '[]'::jsonb;
  v_rec       RECORD;
  v_opp_id    UUID;
BEGIN
  FOR v_rec IN
    SELECT
      v."CO_CURSO",
      v."CO_CAMPUS",
      v."DS_TIPO_BOLSA",
      COALESCE(v."BOLSAS_AMPLA_OFERTADA"::integer, 0) AS bolsas_ampla_ofertada,
      COALESCE(v."BOLSAS_COTA_OFERTADA"::integer, 0)  AS bolsas_cota_ofertada,
      COALESCE(o."BOLSAS_AMPLA_OCUPADA"::integer, 0)  AS bolsas_ampla_ocupada,
      COALESCE(o."BOLSAS_COTA_OCUPADA"::integer, 0)   AS bolsas_cota_ocupada
    FROM rawprounivacancies2025 v
    LEFT JOIN rawprouniocuppied2025 o
      ON  v."CO_CURSO"      = o."CO_CURSO"
      AND v."CO_CAMPUS"     = o."CO_CAMPUS"
      AND v."DS_TIPO_BOLSA" = o."DS_TIPO_BOLSA"
  LOOP
    BEGIN
      -- Resolve opportunity_id via CO_CURSO + CO_CAMPUS
      SELECT op.id INTO v_opp_id
      FROM opportunities op
      JOIN courses c  ON c.id  = op.course_id
      JOIN campus  ca ON ca.id = c.campus_id
      WHERE c.course_code    = v_rec."CO_CURSO"::text
        AND ca.external_code = v_rec."CO_CAMPUS"::text
        AND op.opportunity_type = 'prouni'
      LIMIT 1;

      IF v_opp_id IS NULL THEN
        CONTINUE; -- curso/campus não mapeado ainda, pular sem erro
      END IF;

      INSERT INTO opportunities_prouni_vacancies (
        opportunity_id, ds_tipo_bolsa,
        bolsas_ampla_ofertada, bolsas_cota_ofertada,
        bolsas_ampla_ocupada,  bolsas_cota_ocupada,
        year, semester
      )
      VALUES (
        v_opp_id, v_rec."DS_TIPO_BOLSA",
        v_rec.bolsas_ampla_ofertada, v_rec.bolsas_cota_ofertada,
        v_rec.bolsas_ampla_ocupada,  v_rec.bolsas_cota_ocupada,
        2025, '1'
      )
      ON CONFLICT (opportunity_id, ds_tipo_bolsa)
      DO UPDATE SET
        bolsas_ampla_ofertada = EXCLUDED.bolsas_ampla_ofertada,
        bolsas_cota_ofertada  = EXCLUDED.bolsas_cota_ofertada,
        bolsas_ampla_ocupada  = EXCLUDED.bolsas_ampla_ocupada,
        bolsas_cota_ocupada   = EXCLUDED.bolsas_cota_ocupada,
        updated_at            = now();

      v_processed := v_processed + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'co_curso',  v_rec."CO_CURSO",
          'co_campus', v_rec."CO_CAMPUS",
          'error',     SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object('processed', v_processed, 'errors', v_errors);
END;
$$;

GRANT EXECUTE ON FUNCTION etl_prouni_vacancies() TO service_role;

-- ---------------------------------------------------------------------------
-- RPC 2: etl_sisu_approvals
-- Fonte: rawsisuapprovals2026 (agrega por opportunity + tipo_concorrencia)
-- Destino: opportunities_sisu_approvals
-- Matching: SG_IES + NO_CAMPUS + NO_CURSO + DS_TURNO → opportunities (sisu)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl_sisu_approvals(p_year INTEGER DEFAULT 2026)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_processed INTEGER := 0;
  v_errors    JSONB   := '[]'::jsonb;
  v_rec       RECORD;
  v_opp_id    UUID;
BEGIN
  FOR v_rec IN
    SELECT
      "SG_IES",
      "NO_CAMPUS",
      "NO_CURSO",
      "DS_TURNO",
      "TIPO_CONCORRENCIA",
      MAX("NO_MODALIDADE_CONCORRENCIA") AS modalidade_concorrencia,
      COUNT(*)                          AS qt_aprovados,
      MIN("NU_NOTA_CANDIDATO"::numeric) AS nota_minima,
      MAX("NU_NOTA_CANDIDATO"::numeric) AS nota_maxima,
      AVG("NU_NOTA_CANDIDATO"::numeric) AS nota_media
    FROM rawsisuapprovals2026
    WHERE "NU_NOTA_CANDIDATO" ~ '^[0-9]+(\.[0-9]+)?$' -- só notas numéricas válidas
    GROUP BY "SG_IES", "NO_CAMPUS", "NO_CURSO", "DS_TURNO", "TIPO_CONCORRENCIA"
  LOOP
    BEGIN
      -- Resolve opportunity_id via sigla da IES + nome do campus + nome do curso + turno
      SELECT op.id INTO v_opp_id
      FROM opportunities op
      JOIN courses c  ON c.id  = op.course_id
      JOIN campus  ca ON ca.id = c.campus_id
      JOIN institutions i ON i.id = ca.institution_id
      LEFT JOIN institutionsinfosisu sis ON sis.institution_id = i.id
      WHERE (sis.acronym = v_rec."SG_IES" OR i.name ILIKE '%' || v_rec."SG_IES" || '%')
        AND c.course_name ILIKE v_rec."NO_CURSO"
        AND op.shift      ILIKE v_rec."DS_TURNO"
        AND op.opportunity_type = 'sisu'
      LIMIT 1;

      IF v_opp_id IS NULL THEN
        CONTINUE;
      END IF;

      INSERT INTO opportunities_sisu_approvals (
        opportunity_id, tipo_concorrencia, modalidade_concorrencia,
        qt_aprovados, nota_minima, nota_maxima, nota_media, year
      )
      VALUES (
        v_opp_id,
        v_rec."TIPO_CONCORRENCIA",
        v_rec.modalidade_concorrencia,
        v_rec.qt_aprovados,
        v_rec.nota_minima,
        v_rec.nota_maxima,
        ROUND(v_rec.nota_media, 2),
        p_year
      )
      ON CONFLICT (opportunity_id, tipo_concorrencia, year)
      DO UPDATE SET
        modalidade_concorrencia = EXCLUDED.modalidade_concorrencia,
        qt_aprovados            = EXCLUDED.qt_aprovados,
        nota_minima             = EXCLUDED.nota_minima,
        nota_maxima             = EXCLUDED.nota_maxima,
        nota_media              = EXCLUDED.nota_media,
        updated_at              = now();

      v_processed := v_processed + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'sg_ies',   v_rec."SG_IES",
          'no_curso', v_rec."NO_CURSO",
          'error',    SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object('processed', v_processed, 'errors', v_errors);
END;
$$;

GRANT EXECUTE ON FUNCTION etl_sisu_approvals(INTEGER) TO service_role;

-- ---------------------------------------------------------------------------
-- RPC 3: etl_sisu_vacancies_2026
-- Fonte: rawsisuvacancies2026 → opportunities_sisu_vacancies (rename da Sprint 8.0)
-- Matching: CO_IES_CURSO + DS_TURNO + TP_COTA → opportunities (sisu)
-- Serve para re-importações futuras.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl_sisu_vacancies_2026()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_processed INTEGER := 0;
  v_errors    JSONB   := '[]'::jsonb;
  v_rec       RECORD;
  v_opp_id    UUID;
BEGIN
  FOR v_rec IN
    SELECT * FROM rawsisuvacancies2026
  LOOP
    BEGIN
      -- Resolve opportunity_id via CO_IES_CURSO + DS_TURNO
      SELECT op.id INTO v_opp_id
      FROM opportunities op
      JOIN courses c  ON c.id  = op.course_id
      WHERE c.course_code = v_rec."CO_IES_CURSO"::text
        AND op.shift ILIKE v_rec."DS_TURNO"
        AND op.opportunity_type = 'sisu'
      LIMIT 1;

      IF v_opp_id IS NULL THEN
        CONTINUE;
      END IF;

      INSERT INTO opportunities_sisu_vacancies (opportunity_id)
      VALUES (v_opp_id)
      ON CONFLICT (opportunity_id) DO NOTHING;

      v_processed := v_processed + 1;

    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object('error', SQLERRM)
      );
    END;
  END LOOP;

  RETURN jsonb_build_object('processed', v_processed, 'errors', v_errors);
END;
$$;

GRANT EXECUTE ON FUNCTION etl_sisu_vacancies_2026() TO service_role;
