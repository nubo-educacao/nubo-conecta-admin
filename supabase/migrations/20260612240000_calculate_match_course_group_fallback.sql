-- Migration: calculate_match — course_group fallback
-- Quando o curso exato não existe no ciclo ativo, expande para cursos do mesmo grupo CNPq.
-- Score: 100 exato | 85 prefixo | 70 mesmo grupo | 10 sem relação
-- Depende: course_groups (20260612230000)

DROP FUNCTION IF EXISTS public.calculate_match(UUID);

CREATE OR REPLACE FUNCTION public.calculate_match(p_profile_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_income                NUMERIC;
    v_course_interests      TEXT[];
    v_preferred_shifts      TEXT[];
    v_university_preference TEXT;
    v_program_preference    TEXT;
    v_state_preference      TEXT;
    v_location_preference   TEXT;
    v_lat                   NUMERIC;
    v_lon                   NUMERIC;
    v_quota_types           TEXT[];

    v_nota_linguagens        NUMERIC;
    v_nota_ciencias_humanas  NUMERIC;
    v_nota_ciencias_natureza NUMERIC;
    v_nota_matematica        NUMERIC;
    v_nota_redacao           NUMERIC;
    v_enem_avg               NUMERIC;
    v_has_enem               BOOLEAN := false;
    v_is_treineiro_score     BOOLEAN := false;

    v_weights              JSONB;
    v_enem_window_sisu     INT     := 3;
    v_salario_minimo       NUMERIC := 1518.00;
    v_has_funnel_filters   BOOLEAN;

    v_sisu_year       INT;
    v_sisu_semester   TEXT;
    v_prouni_year     INT;
    v_prouni_semester TEXT;

    -- Course group fallback
    v_course_group_courses TEXT[];
BEGIN
    -- 0. Active cycles
    SELECT cycle_year, cycle_semester INTO v_sisu_year, v_sisu_semester
    FROM public.programs WHERE LOWER(type) = 'sisu' AND status <> 'inactive'
    ORDER BY cycle_year DESC, cycle_semester DESC LIMIT 1;

    SELECT cycle_year, cycle_semester INTO v_prouni_year, v_prouni_semester
    FROM public.programs WHERE LOWER(type) = 'prouni' AND status <> 'inactive'
    ORDER BY cycle_year DESC, cycle_semester DESC LIMIT 1;

    IF v_sisu_year IS NULL    THEN v_sisu_year := 2025;    v_sisu_semester := '1'; END IF;
    IF v_prouni_year IS NULL  THEN v_prouni_year := 2025;  v_prouni_semester := '1'; END IF;

    -- 1. User preferences
    SELECT
        up.family_income_per_capita, up.course_interest, up.preferred_shifts,
        up.university_preference, up.program_preference, up.state_preference,
        up.location_preference, up.device_latitude, up.device_longitude, up.quota_types
    INTO
        v_income, v_course_interests, v_preferred_shifts,
        v_university_preference, v_program_preference, v_state_preference,
        v_location_preference, v_lat, v_lon, v_quota_types
    FROM public.user_preferences up WHERE up.user_id = p_profile_id;

    -- 2. ENEM scores
    SELECT ues.nota_linguagens, ues.nota_ciencias_humanas, ues.nota_ciencias_natureza,
           ues.nota_matematica, ues.nota_redacao
    INTO   v_nota_linguagens, v_nota_ciencias_humanas, v_nota_ciencias_natureza,
           v_nota_matematica, v_nota_redacao
    FROM public.user_enem_scores ues
    WHERE ues.user_id = p_profile_id AND ues.is_treineiro = false
      AND ues.year >= (EXTRACT(YEAR FROM CURRENT_DATE)::INT - v_enem_window_sisu)
    ORDER BY (COALESCE(ues.nota_linguagens,0)+COALESCE(ues.nota_ciencias_humanas,0)+
              COALESCE(ues.nota_ciencias_natureza,0)+COALESCE(ues.nota_matematica,0)+
              COALESCE(ues.nota_redacao,0)) DESC LIMIT 1;

    IF v_nota_linguagens IS NULL THEN
        SELECT ues.nota_linguagens, ues.nota_ciencias_humanas, ues.nota_ciencias_natureza,
               ues.nota_matematica, ues.nota_redacao
        INTO   v_nota_linguagens, v_nota_ciencias_humanas, v_nota_ciencias_natureza,
               v_nota_matematica, v_nota_redacao
        FROM public.user_enem_scores ues
        WHERE ues.user_id = p_profile_id AND ues.is_treineiro = true
          AND ues.year >= (EXTRACT(YEAR FROM CURRENT_DATE)::INT - v_enem_window_sisu)
        ORDER BY (COALESCE(ues.nota_linguagens,0)+COALESCE(ues.nota_ciencias_humanas,0)+
                  COALESCE(ues.nota_ciencias_natureza,0)+COALESCE(ues.nota_matematica,0)+
                  COALESCE(ues.nota_redacao,0)) DESC LIMIT 1;
        IF v_nota_linguagens IS NOT NULL THEN v_is_treineiro_score := true; END IF;
    END IF;

    IF v_nota_linguagens IS NOT NULL THEN
        v_has_enem := true;
        v_enem_avg := (COALESCE(v_nota_linguagens,0)+COALESCE(v_nota_ciencias_humanas,0)+
                       COALESCE(v_nota_ciencias_natureza,0)+COALESCE(v_nota_matematica,0)+
                       COALESCE(v_nota_redacao,0)) / 5.0;
    END IF;

    -- 3. Weights
    SELECT jsonb_object_agg(weight_key, weight_value) INTO v_weights
    FROM public.match_config WHERE is_active = true;
    IF v_weights IS NULL THEN
        v_weights := '{"performance_weight":0.40,"preference_weight":0.30,"location_weight":0.20,
                       "partner_boost":1.15,"partner_boost_cap":20,"idle_vacancy_boost":5,"cota_bonus":10,
                       "score_decay_above_cutoff":0.3,"score_decay_below_cutoff":0.9}'::jsonb;
    END IF;

    -- 4. Course group fallback
    -- Se o usuário tem interesse em cursos, busca o grupo correspondente no CNPq.
    -- Usado no Path A para expandir o filtro quando o curso exato não existe no ciclo ativo.
    IF v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0 THEN
        SELECT array_agg(DISTINCT unnest_courses) INTO v_course_group_courses
        FROM (
            SELECT unnest(cg.courses) AS unnest_courses
            FROM public.course_groups cg
            WHERE EXISTS (
                SELECT 1 FROM unnest(v_course_interests) ci
                WHERE cg.courses @> ARRAY[UPPER(ci)]
            )
        ) sub;
    END IF;

    -- 5. Funnel filter flag
    v_has_funnel_filters := (
        (v_program_preference IS NOT NULL AND v_program_preference != 'indiferente') OR
        (v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0) OR
        v_state_preference IS NOT NULL OR
        (v_preferred_shifts IS NOT NULL AND cardinality(v_preferred_shifts) > 0)
    );

    -- 6. Clear old matches
    DELETE FROM public.user_opportunity_matches WHERE profile_id = p_profile_id;

    -- 7. MEC funnel
    CREATE TEMP TABLE _mec_funnel (
        opp_id              uuid,
        unified_id          text,
        course_id           uuid,
        course_name         text,
        opportunity_type    text,
        scholarship_type    text,
        concurrency_type    text,
        concurrency_tags    jsonb,
        cutoff_score        numeric,
        shift               text,
        is_partner          boolean,
        campus_lat          numeric,
        campus_lon          numeric,
        campus_state        text,
        campus_city         text,
        institution_id      uuid,
        peso_linguagens     numeric,
        peso_ciencias_humanas numeric,
        peso_ciencias_natureza numeric,
        peso_matematica     numeric,
        peso_redacao        numeric,
        has_vagas_ociosas   boolean,
        eligibility_criteria jsonb
    ) ON COMMIT DROP;

    IF v_has_funnel_filters THEN
        -- Path A: funnel com fallback por grupo CNPq quando curso exato não existe no ciclo
        INSERT INTO _mec_funnel
        SELECT o.id, 'mec_'||c.id::text, o.course_id, c.course_name,
               o.opportunity_type, o.scholarship_type, o.concurrency_type, o.concurrency_tags,
               o.cutoff_score, o.shift, false,
               cp.latitude, cp.longitude, cp.state, cp.city, i.id,
               sv.peso_linguagens, sv.peso_ciencias_humanas, sv.peso_ciencias_natureza,
               sv.peso_matematica, sv.peso_redacao,
               EXISTS (
                   SELECT 1 FROM public.opportunities_sisu_vacancies sv2
                   WHERE sv2.opportunity_id = o.id
                     AND sv2.qt_vagas_ofertadas IS NOT NULL
                     AND sv2.qt_inscricao IS NOT NULL
                     AND replace(sv2.qt_vagas_ofertadas, '.', '')::int > sv2.qt_inscricao::int
               ),
               NULL::jsonb
        FROM public.opportunities o
        JOIN public.courses c      ON c.id = o.course_id
        JOIN public.campus cp      ON cp.id = c.campus_id
        JOIN public.institutions i ON i.id = cp.institution_id
        LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
        WHERE (
            (o.opportunity_type = 'sisu'   AND o.year = v_sisu_year   AND o.semester = v_sisu_semester) OR
            (o.opportunity_type = 'prouni' AND o.year = v_prouni_year AND o.semester = v_prouni_semester)
        )
          AND (v_program_preference IS NULL OR v_program_preference = 'indiferente'
               OR o.opportunity_type = v_program_preference)
          AND (
              -- Sem filtro de curso → passa tudo
              v_course_interests IS NULL OR cardinality(v_course_interests) = 0
              OR
              -- Match exato ou prefixo no nome do curso
              EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                      WHERE c.course_name ILIKE '%'||ci||'%')
              OR
              -- Fallback: curso pertence ao mesmo grupo CNPq do interesse
              (v_course_group_courses IS NOT NULL
               AND UPPER(c.course_name) = ANY(v_course_group_courses))
          )
          AND (v_state_preference IS NULL OR cp.state = v_state_preference)
          AND (v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts) = 0
               OR o.shift = ANY(v_preferred_shifts))
        ORDER BY o.cutoff_score DESC NULLS LAST
        LIMIT 1500;

    ELSIF v_lat IS NOT NULL AND v_lon IS NOT NULL THEN
        -- Path B: geolocalização
        INSERT INTO _mec_funnel
        SELECT o.id, 'mec_'||c.id::text, o.course_id, c.course_name,
               o.opportunity_type, o.scholarship_type, o.concurrency_type, o.concurrency_tags,
               o.cutoff_score, o.shift, false,
               cp.latitude, cp.longitude, cp.state, cp.city, i.id,
               sv.peso_linguagens, sv.peso_ciencias_humanas, sv.peso_ciencias_natureza,
               sv.peso_matematica, sv.peso_redacao,
               EXISTS (
                   SELECT 1 FROM public.opportunities_sisu_vacancies sv2
                   WHERE sv2.opportunity_id = o.id
                     AND sv2.qt_vagas_ofertadas IS NOT NULL
                     AND sv2.qt_inscricao IS NOT NULL
                     AND replace(sv2.qt_vagas_ofertadas, '.', '')::int > sv2.qt_inscricao::int
               ),
               NULL::jsonb
        FROM public.opportunities o
        JOIN public.courses c      ON c.id = o.course_id
        JOIN public.campus cp      ON cp.id = c.campus_id
        JOIN public.institutions i ON i.id = cp.institution_id
        LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
        WHERE (
            (o.opportunity_type = 'sisu'   AND o.year = v_sisu_year   AND o.semester = v_sisu_semester) OR
            (o.opportunity_type = 'prouni' AND o.year = v_prouni_year AND o.semester = v_prouni_semester)
        )
          AND cp.latitude IS NOT NULL AND cp.longitude IS NOT NULL
          AND public.haversine_km(v_lat, v_lon, cp.latitude, cp.longitude) <= 500
        ORDER BY o.cutoff_score DESC NULLS LAST
        LIMIT 1500;

    ELSE
        -- Path C: hash random
        INSERT INTO _mec_funnel
        SELECT o.id, 'mec_'||c.id::text, o.course_id, c.course_name,
               o.opportunity_type, o.scholarship_type, o.concurrency_type, o.concurrency_tags,
               o.cutoff_score, o.shift, false,
               cp.latitude, cp.longitude, cp.state, cp.city, i.id,
               sv.peso_linguagens, sv.peso_ciencias_humanas, sv.peso_ciencias_natureza,
               sv.peso_matematica, sv.peso_redacao,
               EXISTS (
                   SELECT 1 FROM public.opportunities_sisu_vacancies sv2
                   WHERE sv2.opportunity_id = o.id
                     AND sv2.qt_vagas_ofertadas IS NOT NULL
                     AND sv2.qt_inscricao IS NOT NULL
                     AND replace(sv2.qt_vagas_ofertadas, '.', '')::int > sv2.qt_inscricao::int
               ),
               NULL::jsonb
        FROM public.opportunities o
        JOIN public.courses c      ON c.id = o.course_id
        JOIN public.campus cp      ON cp.id = c.campus_id
        JOIN public.institutions i ON i.id = cp.institution_id
        LEFT JOIN public.opportunities_sisu_vacancies sv ON sv.opportunity_id = o.id
        WHERE (
            (o.opportunity_type = 'sisu'   AND o.year = v_sisu_year   AND o.semester = v_sisu_semester) OR
            (o.opportunity_type = 'prouni' AND o.year = v_prouni_year AND o.semester = v_prouni_semester)
        )
        ORDER BY hashtext(c.id::text || p_profile_id::text)
        LIMIT 1000;
    END IF;

    -- 8. Score and persist
    INSERT INTO public.user_opportunity_matches
        (profile_id, unified_opportunity_id, match_score, match_details)

    WITH

    all_opportunities AS (
        SELECT * FROM _mec_funnel

        UNION ALL

        SELECT po.id, 'partner_'||po.id::text, NULL::uuid, po.name,
               'partner', NULL, NULL, NULL::jsonb, NULL::numeric, NULL,
               true, NULL::numeric, NULL::numeric, NULL, NULL,
               po.institution_id, NULL, NULL, NULL, NULL, NULL, false::boolean,
               po.eligibility_criteria
        FROM public.partner_opportunities po
        WHERE po.status::text IN ('approved', 'incoming', 'opened')
    ),

    scored_performance AS (
        SELECT
            ao.*,
            CASE
                WHEN ao.opportunity_type = 'prouni' AND ao.scholarship_type ILIKE '%Integral%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 1.5 THEN false
                WHEN ao.opportunity_type = 'prouni' AND ao.scholarship_type ILIKE '%Parcial%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 3.0 THEN false
                WHEN ao.opportunity_type = 'sisu' AND ao.concurrency_type ILIKE '%renda%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 1.5 THEN false
                WHEN ao.is_partner
                     AND ao.eligibility_criteria->>'per_capita_income_limit' IS NOT NULL
                     AND v_income IS NOT NULL
                     AND v_income > (ao.eligibility_criteria->>'per_capita_income_limit')::numeric
                THEN false
                ELSE true
            END AS meets_income,
            CASE
                WHEN ao.concurrency_tags IS NULL OR jsonb_array_length(ao.concurrency_tags) = 0 THEN false
                WHEN v_quota_types IS NULL OR cardinality(v_quota_types) = 0 THEN false
                WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(ao.concurrency_tags) AS tag_set
                    WHERE NOT EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(tag_set) AS tag
                        WHERE NOT (tag = ANY(v_quota_types))
                    )
                ) THEN true
                ELSE false
            END AS cota_eligible,
            CASE
                WHEN v_has_enem AND ao.peso_linguagens IS NOT NULL THEN
                    (COALESCE(v_nota_linguagens,0)*COALESCE(ao.peso_linguagens::numeric,1)+
                     COALESCE(v_nota_ciencias_humanas,0)*COALESCE(ao.peso_ciencias_humanas::numeric,1)+
                     COALESCE(v_nota_ciencias_natureza,0)*COALESCE(ao.peso_ciencias_natureza::numeric,1)+
                     COALESCE(v_nota_matematica,0)*COALESCE(ao.peso_matematica::numeric,1)+
                     COALESCE(v_nota_redacao,0)*COALESCE(ao.peso_redacao::numeric,1))
                    / NULLIF(COALESCE(ao.peso_linguagens::numeric,1)+COALESCE(ao.peso_ciencias_humanas::numeric,1)+
                             COALESCE(ao.peso_ciencias_natureza::numeric,1)+COALESCE(ao.peso_matematica::numeric,1)+
                             COALESCE(ao.peso_redacao::numeric,1), 0)
                WHEN v_has_enem THEN v_enem_avg
                ELSE NULL
            END AS weighted_enem_score
        FROM all_opportunities ao
    ),

    scored_academic AS (
        SELECT sp.*,
            CASE
                WHEN sp.weighted_enem_score IS NOT NULL AND sp.cutoff_score IS NOT NULL AND sp.cutoff_score > 0 THEN
                    GREATEST(0.0, LEAST(100.0,
                        (100.0 - CASE
                            WHEN sp.weighted_enem_score >= sp.cutoff_score THEN
                                (sp.weighted_enem_score - sp.cutoff_score) * COALESCE((v_weights->>'score_decay_above_cutoff')::NUMERIC, 0.3)
                            ELSE
                                (sp.cutoff_score - sp.weighted_enem_score) * COALESCE((v_weights->>'score_decay_below_cutoff')::NUMERIC, 0.9)
                         END)
                        * CASE WHEN v_is_treineiro_score THEN 0.85 ELSE 1.0 END))
                WHEN sp.weighted_enem_score IS NOT NULL THEN
                    LEAST(100.0, (sp.weighted_enem_score/700.0)*100.0
                        * CASE WHEN v_is_treineiro_score THEN 0.85 ELSE 1.0 END)
                ELSE 50.0
            END AS academic_score
        FROM scored_performance sp
    ),

    scored_preferences AS (
        SELECT sa.*,
            CASE WHEN v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts)=0 THEN 50.0
                 WHEN sa.shift IS NULL THEN 50.0
                 WHEN sa.shift = ANY(v_preferred_shifts) THEN 100.0
                 ELSE 0.0 END AS shift_score,
            CASE WHEN v_university_preference IS NULL OR v_university_preference='indiferente' THEN 50.0
                 WHEN v_university_preference='publica'  AND sa.opportunity_type='sisu'               THEN 100.0
                 WHEN v_university_preference='privada'  AND sa.opportunity_type IN ('prouni','partner') THEN 100.0
                 ELSE 20.0 END
            + CASE WHEN v_program_preference IS NULL OR v_program_preference='indiferente' THEN 50.0
                   WHEN v_program_preference='sisu'   AND sa.opportunity_type='sisu'   THEN 100.0
                   WHEN v_program_preference='prouni' AND sa.opportunity_type='prouni' THEN 100.0
                   ELSE 20.0 END AS inst_program_score_raw,
            CASE
                -- Exato (case-insensitive)
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                                 WHERE LOWER(sa.course_name) = LOWER(ci)) THEN 100.0
                -- Prefixo / substring
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                                 WHERE sa.course_name ILIKE '%'||ci||'%') THEN 85.0
                -- Mesmo grupo CNPq (fallback)
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND v_course_group_courses IS NOT NULL
                     AND UPPER(sa.course_name) = ANY(v_course_group_courses) THEN 70.0
                -- Sem preferência de curso
                WHEN v_course_interests IS NULL OR cardinality(v_course_interests) = 0 THEN 50.0
                ELSE 10.0
            END AS course_score
        FROM scored_academic sa
    ),

    scored_location AS (
        SELECT sp.*,
            LEAST(100.0, sp.inst_program_score_raw/2.0) AS inst_program_score,
            CASE
                WHEN v_lat IS NOT NULL AND v_lon IS NOT NULL
                     AND sp.campus_lat IS NOT NULL AND sp.campus_lon IS NOT NULL THEN
                    GREATEST(0.0, 100.0 - public.haversine_km(v_lat, v_lon, sp.campus_lat, sp.campus_lon)*0.5)
                ELSE 40.0
            END AS distance_score,
            CASE WHEN v_state_preference IS NOT NULL AND sp.campus_state IS NOT NULL
                      AND LOWER(sp.campus_state)=LOWER(v_state_preference) THEN 30.0
                 WHEN v_location_preference IS NOT NULL AND sp.campus_city IS NOT NULL
                      AND LOWER(sp.campus_city) ILIKE '%'||LOWER(v_location_preference)||'%' THEN 30.0
                 ELSE 0.0 END AS regional_bonus
        FROM scored_preferences sp
    ),

    composite AS (
        SELECT sl.opp_id, sl.concurrency_type, sl.concurrency_tags,
               sl.unified_id, sl.course_id, sl.is_partner, sl.meets_income, sl.cota_eligible,
               sl.academic_score, sl.shift_score, sl.inst_program_score, sl.course_score,
               sl.distance_score, sl.regional_bonus, sl.weighted_enem_score, sl.cutoff_score,
               sl.has_vagas_ociosas, sl.opportunity_type,
               CASE WHEN sl.meets_income THEN
                   LEAST(100.0, GREATEST(0.0,
                       COALESCE((v_weights->>'performance_weight')::NUMERIC,0.40)*sl.academic_score
                       + COALESCE((v_weights->>'preference_weight')::NUMERIC,0.30)*(
                           sl.shift_score*0.333 + sl.inst_program_score*0.333 + sl.course_score*0.334)
                       + COALESCE((v_weights->>'location_weight')::NUMERIC,0.20)*(
                           LEAST(100.0, sl.distance_score + sl.regional_bonus))))
               ELSE 0.0 END AS base_score
        FROM scored_location sl
    ),

    boosted AS (
        SELECT c.*,
            CASE WHEN NOT c.meets_income THEN 0.0
                 WHEN c.is_partner THEN
                     LEAST(c.base_score*COALESCE((v_weights->>'partner_boost')::NUMERIC,1.15),
                           c.base_score+COALESCE((v_weights->>'partner_boost_cap')::NUMERIC,20.0))
                 ELSE c.base_score END
            + CASE WHEN c.has_vagas_ociosas AND c.meets_income THEN
                       COALESCE((v_weights->>'idle_vacancy_boost')::NUMERIC, 5.0)
                   ELSE 0.0 END
            + CASE WHEN c.cota_eligible AND c.meets_income THEN
                       COALESCE((v_weights->>'cota_bonus')::NUMERIC,10.0)
                   ELSE 0.0 END AS final_score,
            jsonb_build_object(
                'meets_income', c.meets_income, 'cota_eligible', c.cota_eligible,
                'treineiro_score', v_is_treineiro_score,
                'academic_score', round(c.academic_score,2),
                'weighted_enem_score', round(COALESCE(c.weighted_enem_score,0),2),
                'cutoff_score', COALESCE(c.cutoff_score,0),
                'shift_score', round(c.shift_score,2),
                'inst_program_score', round(c.inst_program_score,2),
                'course_score', round(c.course_score,2),
                'distance_score', round(c.distance_score,2),
                'regional_bonus', round(c.regional_bonus,2),
                'base_score', round(c.base_score,2),
                'is_partner', c.is_partner,
                'boost_applied', c.is_partner AND c.meets_income,
                'idle_vacancy_boost_applied', c.has_vagas_ociosas,
                'cota_bonus_applied', (c.cota_eligible AND c.meets_income),
                'opportunity_type', c.opportunity_type,
                'best_opportunity_id', c.opp_id,
                'best_concurrency_type', c.concurrency_type,
                'best_concurrency_tags', c.concurrency_tags,
                'cycle', jsonb_build_object('sisu_year',v_sisu_year,'sisu_semester',v_sisu_semester,
                                             'prouni_year',v_prouni_year,'prouni_semester',v_prouni_semester)
            ) AS details
        FROM composite c
    ),

    course_best AS (
        SELECT DISTINCT ON (COALESCE(b.course_id::text, b.unified_id))
            b.unified_id, b.is_partner,
            LEAST(100.0, round(b.final_score,2)) AS final_score,
            b.details
        FROM boosted b
        ORDER BY COALESCE(b.course_id::text, b.unified_id), b.final_score DESC
    ),

    mec_top100 AS (
        SELECT unified_id, is_partner, final_score, details
        FROM course_best WHERE NOT is_partner
        ORDER BY final_score DESC LIMIT 100
    ),

    partners_all AS (
        SELECT unified_id, is_partner, final_score, details
        FROM course_best WHERE is_partner
    )

    SELECT p_profile_id, unified_id, final_score, details FROM mec_top100
    UNION ALL
    SELECT p_profile_id, unified_id, final_score, details FROM partners_all;

END;
$$;

COMMENT ON FUNCTION public.calculate_match IS 'V4.1: Adiciona fallback por grupo CNPq quando curso exato não existe no ciclo ativo. Score: 100 exato | 85 substring | 70 grupo | 10 sem relação.';
