-- Migration para corrigir referências às tabelas antigas em RPCs esquecidas

-- 1. Corrige o etl_sisu_approvals (que referia-se a institutionsinfosisu)
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
      LEFT JOIN institutions_info_sisu sis ON sis.institution_id = i.id
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

-- 2. Corrige match_opportunities (que referia-se a institutionsinfoemec)
CREATE OR REPLACE FUNCTION match_opportunities(p_user_id UUID, page_number INT, page_size INT)
RETURNS TABLE (
  course_id UUID,
  course_name TEXT,
  institution_name TEXT,
  campus_city TEXT,
  campus_state TEXT,
  distance_km NUMERIC,
  opportunity_id UUID,
  scholarship_type TEXT,
  concurrency_type TEXT,
  cutoff_score NUMERIC,
  shift TEXT,
  concurrency_tags JSONB,
  opportunity_type TEXT,
  institution_igc NUMERIC,
  nota_ponderada NUMERIC,
  score_year INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_base_enem_score numeric;
BEGIN
  -- Force Index Usage
  SET LOCAL enable_seqscan = off;

  -- 1. Get base score from preferences
  SELECT enem_score INTO v_base_enem_score 
  FROM user_preferences 
  WHERE user_id = p_user_id;

  RETURN QUERY
  WITH matching_opportunities AS (
    SELECT 
      o.id as opp_id,
      o.course_id,
      o.scholarship_type,
      o.concurrency_type,
      o.cutoff_score,
      o.shift,
      o.concurrency_tags,
      o.opportunity_type,
      c.course_name,
      c.campus_id
    FROM opportunities o
    JOIN courses c ON o.course_id = c.id
    WHERE 
      o.semester = '1'
      
      -- Focus on ProUni 2025 (or Sisu 2026 if requested)
      AND (
        (program_preference ILIKE '%sisu%' AND o.opportunity_type = 'sisu' AND o.year = 2026) 
        OR
        ((program_preference ILIKE '%prouni%' OR program_preference IS NULL OR program_preference = 'indiferente') AND o.opportunity_type = 'prouni' AND o.year = 2025)
      )

      -- Shift Filter
      AND (
        preferred_shifts IS NULL 
        OR cardinality(preferred_shifts) = 0 
        OR o.shift = ANY(preferred_shifts)
      )
      
      -- Income Logic for ProUni
      AND (
         income_per_capita IS NULL OR
         o.opportunity_type <> 'prouni' OR
         NOT (
           (income_per_capita > 4554 AND ( -- > 3 MW
              o.scholarship_type ILIKE '%Parcial%' OR o.scholarship_type ILIKE '%Integral%'
           ))
           OR
           (income_per_capita > 2277 AND ( -- > 1.5 MW
              o.scholarship_type ILIKE '%Integral%'
           ))
         )
      )

      -- Quota Logic (ProUni Specific)
      AND (
        quota_types IS NULL OR cardinality(quota_types) = 0
        OR o.opportunity_type <> 'prouni'
        OR (
           COALESCE(o.concurrency_tags, '[]'::jsonb)::text ILIKE '%"AMPLA_CONCORRENCIA"%'
           OR 
           EXISTS (
             SELECT 1 FROM unnest(quota_types) q
             WHERE COALESCE(o.concurrency_tags, '[]'::jsonb)::text ILIKE '%"' || q || '"%'
           )
        )
      )
      
      -- Course Filter (ILIKE Search)
      AND (
        course_interests IS NULL 
        OR cardinality(course_interests) = 0
        OR EXISTS (
            SELECT 1 FROM unnest(course_interests) AS interest
            WHERE c.course_name ILIKE '%' || interest || '%'
        )
      )

      -- Location Filters (City/State)
      AND (
        state_names IS NULL 
        OR cardinality(state_names) = 0
        OR EXISTS (
            SELECT 1 FROM campus cp WHERE cp.id = c.campus_id
            AND (
                cp.state ILIKE ANY(SELECT unnest(state_names))
                OR
                cp.state IN (SELECT uf FROM states WHERE name ILIKE ANY(SELECT unnest(state_names)))
            )
        )
      )
      AND (
        city_names IS NULL 
        OR cardinality(city_names) = 0
        OR EXISTS (
            SELECT 1 FROM campus cp WHERE cp.id = c.campus_id
            AND f_unaccent(cp.city) ILIKE ANY(SELECT f_unaccent(unnest(city_names)))
        )
      )
      
      -- SCORE MATCH (Basic ProUni Logic)
      -- Show if: 
      -- 1. No cutoff score exists (rare)
      -- 2. User has no score (Exploratory mode)
      -- 3. User score >= Cutoff
      AND (
        o.cutoff_score IS NULL 
        OR v_base_enem_score IS NULL 
        OR v_base_enem_score >= o.cutoff_score
      )
  )
  
  SELECT
    c.id as course_id, c.course_name, i.name as institution_name,
    cp.city as campus_city, cp.state as campus_state,
    CASE 
        WHEN user_lat IS NOT NULL AND user_long IS NOT NULL 
             AND cp.latitude IS NOT NULL AND cp.longitude IS NOT NULL THEN
          (point(cp.longitude, cp.latitude) <@> point(user_long, user_lat)) * 1.60934
        ELSE NULL 
    END as distance_km,
    
    mo.opp_id as opportunity_id, mo.scholarship_type, mo.concurrency_type,
    mo.cutoff_score, mo.shift, mo.concurrency_tags, mo.opportunity_type,
    NULLIF(info.igc, '')::numeric as institution_igc,
    
    COALESCE(v_base_enem_score, 0) as nota_ponderada,
    0 as score_year

  FROM matching_opportunities mo
  JOIN courses c ON mo.course_id = c.id
  JOIN campus cp ON c.campus_id = cp.id
  JOIN institutions i ON cp.institution_id = i.id
  LEFT JOIN (
      SELECT DISTINCT ON (institution_id) *
      FROM institutions_info_emec
      ORDER BY institution_id, id DESC
  ) info ON i.id = info.institution_id
  
  ORDER BY
    -- Prioritize results user actually qualifies for (if score exists)
    CASE WHEN v_base_enem_score >= mo.cutoff_score THEN 1 ELSE 0 END DESC,
    
    -- Then standard ordering
    (COALESCE(v_base_enem_score, 0) - COALESCE(mo.cutoff_score, 0)) DESC NULLS LAST,
    distance_km ASC NULLS LAST,
    info.igc DESC NULLS LAST,
    c.course_name ASC
  LIMIT page_size OFFSET page_number * page_size;
END;
$$;
