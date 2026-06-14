-- Migration: motor de elegibilidade de parceiro + separação MEC × parceiro no match (V4.3)
--
-- CONTEXTO: o match de partner_opportunities NÃO usa ENEM/nota de corte. Ele usa os
-- critérios configurados em partner_forms (is_criterion = true), avaliados via JsonLogic
-- (criterion_rule) contra os dados do usuário resolvidos por mapping_source
-- (user_profiles.age/education/education_year/state, user_income.per_capita_income).
--
-- Até aqui o calculate_match jogava o parceiro no MESMO pipeline do MEC (academic ENEM +
-- shift + course + distance), o que produzia score sem sentido (ex.: BIP 67,84% sustentado
-- por academic=100 herdado do ENEM 999). Esta migration:
--   1. Cria o engine de avaliação (helpers puros + evaluate_partner_eligibility).
--   2. Refatora calculate_match (V4.3): parceiro pontua por elegibilidade (met/total),
--      fora do pipeline acadêmico; MEC mantém ENEM/corte. Aplica também o piso acadêmico
--      aos cursos MEC sem nota de corte (antes davam 100 via heurística enem/700).

-- ============================================================================
-- 1. Helper puro: normaliza valores "sujos" para numérico
--    "17 anos" → 17 | "3242,00" → 3242.00 | "7294,5" → 7294.5
-- ============================================================================
CREATE OR REPLACE FUNCTION public._eligib_to_num(p_text text)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
    SELECT NULLIF(
        regexp_replace(replace(btrim(p_text), ',', '.'), '[^0-9.]', '', 'g'),
        ''
    )::numeric;
$$;

COMMENT ON FUNCTION public._eligib_to_num(text) IS
'Extrai numérico de strings sujas usadas em partner_forms.criterion_rule (ex.: "17 anos", "3242,00").';

-- ============================================================================
-- 2. Helper puro: avalia UMA folha JsonLogic { op: [ {var:..}, literal ] }
--    contra o valor já resolvido do usuário (texto + numérico pré-convertido).
--    Convenção (confirmada nos dados reais): var é arg0, literal é arg1.
--    Comparações de texto (== / in) são case-insensitive e trimmed.
-- ============================================================================
CREATE OR REPLACE FUNCTION public._eligib_eval_leaf(
    p_val_text text,
    p_val_num  numeric,
    p_leaf     jsonb
)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_op   text;
    v_args jsonb;
    v_lit  jsonb;
BEGIN
    SELECT key INTO v_op FROM jsonb_each(p_leaf) LIMIT 1;
    v_args := p_leaf -> v_op;

    IF v_args IS NULL OR jsonb_typeof(v_args) <> 'array' THEN
        RETURN true;  -- formato inesperado → não bloqueia (fail-open por folha)
    END IF;

    -- literal = elemento que NÃO é o {var}
    v_lit := CASE WHEN (v_args->0) ? 'var' THEN v_args->1 ELSE v_args->0 END;

    CASE v_op
        WHEN '==' THEN
            RETURN lower(btrim(p_val_text)) = lower(btrim(v_lit #>> '{}'));
        WHEN 'in' THEN
            RETURN EXISTS (
                SELECT 1 FROM jsonb_array_elements_text(v_lit) AS opt
                WHERE lower(btrim(opt)) = lower(btrim(p_val_text))
            );
        WHEN '<'  THEN RETURN p_val_num <  public._eligib_to_num(v_lit #>> '{}');
        WHEN '>'  THEN RETURN p_val_num >  public._eligib_to_num(v_lit #>> '{}');
        WHEN '<=' THEN RETURN p_val_num <= public._eligib_to_num(v_lit #>> '{}');
        WHEN '>=' THEN RETURN p_val_num >= public._eligib_to_num(v_lit #>> '{}');
        ELSE
            RETURN true;  -- operador desconhecido → não bloqueia
    END CASE;
EXCEPTION WHEN OTHERS THEN
    RETURN false;  -- erro de cast/comparação → critério não atendido
END;
$$;

COMMENT ON FUNCTION public._eligib_eval_leaf(text, numeric, jsonb) IS
'Avalia uma folha JsonLogic (==, in, <, <=, >, >=) de partner_forms contra o valor do usuário.';

-- ============================================================================
-- 3. Avaliador de elegibilidade a nível de PERFIL (pré-aplicação)
--    Itera os critérios de um partner_opportunity, resolve cada um por
--    mapping_source e avalia o criterion_rule (suporta and/or de folhas).
--    Convenção (espelha calculate_application_eligibility): só conta no total
--    o critério cujo valor é resolvível; critério sem mapping_source/sem dado
--    é ignorado (não penaliza). total = 0 → score 100 (sem barreiras).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.evaluate_partner_eligibility(
    p_profile_id uuid,
    p_partner_opportunity_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
    v_profile    public.user_profiles%ROWTYPE;
    v_income     numeric;
    v_form       RECORD;
    v_total      int := 0;
    v_met        int := 0;
    v_val_text   text;
    v_val_num    numeric;
    v_rule       jsonb;
    v_cond       jsonb;
    v_ok         boolean;
    v_details    jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO v_profile FROM public.user_profiles WHERE id = p_profile_id;

    SELECT per_capita_income INTO v_income
    FROM public.user_income WHERE user_id = p_profile_id
    ORDER BY updated_at DESC NULLS LAST LIMIT 1;

    FOR v_form IN
        SELECT field_name, mapping_source, criterion_rule
        FROM public.partner_forms
        WHERE partner_id = p_partner_opportunity_id AND is_criterion = true
    LOOP
        -- resolve valor via mapping_source
        v_val_text := CASE v_form.mapping_source
            WHEN 'user_profiles.age'             THEN v_profile.age::text
            WHEN 'user_profiles.education'        THEN v_profile.education
            WHEN 'user_profiles.education_year'   THEN v_profile.education_year
            WHEN 'user_profiles.state'            THEN v_profile.state
            WHEN 'user_income.per_capita_income'  THEN v_income::text
            ELSE NULL  -- campo sem mapeamento (só respondível no form) → ignora
        END;

        IF v_val_text IS NULL OR btrim(v_val_text) = '' OR v_val_text = 'N/A' THEN
            CONTINUE;  -- não avaliável → fora do total
        END IF;

        v_total  := v_total + 1;
        v_val_num := public._eligib_to_num(v_val_text);
        v_rule   := v_form.criterion_rule;

        IF v_rule IS NULL THEN
            v_ok := true;
        ELSIF v_rule ? 'and' THEN
            v_ok := true;
            FOR v_cond IN SELECT * FROM jsonb_array_elements(v_rule->'and') LOOP
                IF NOT public._eligib_eval_leaf(v_val_text, v_val_num, v_cond) THEN
                    v_ok := false; EXIT;
                END IF;
            END LOOP;
        ELSIF v_rule ? 'or' THEN
            v_ok := false;
            FOR v_cond IN SELECT * FROM jsonb_array_elements(v_rule->'or') LOOP
                IF public._eligib_eval_leaf(v_val_text, v_val_num, v_cond) THEN
                    v_ok := true; EXIT;
                END IF;
            END LOOP;
        ELSE
            v_ok := public._eligib_eval_leaf(v_val_text, v_val_num, v_rule);
        END IF;

        IF v_ok THEN v_met := v_met + 1; END IF;
        v_details := v_details || jsonb_build_object('field', v_form.field_name, 'met', v_ok);
    END LOOP;

    RETURN jsonb_build_object(
        'total', v_total,
        'met',   v_met,
        'score', CASE WHEN v_total = 0 THEN 100.0
                      ELSE round((v_met::numeric / v_total) * 100, 2) END,
        'details', v_details
    );
END;
$$;

COMMENT ON FUNCTION public.evaluate_partner_eligibility(uuid, uuid) IS
'Score de elegibilidade (met/total*100) de um perfil para um partner_opportunity, via partner_forms+JsonLogic. total=0 → 100.';

-- ============================================================================
-- 4. calculate_match V4.3 — parceiro separado do pipeline MEC
-- ============================================================================
CREATE OR REPLACE FUNCTION public.calculate_match(p_profile_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
    v_salario_minimo       NUMERIC := 1621.00;
    v_has_funnel_filters   BOOLEAN;

    v_sisu_year       INT;
    v_sisu_semester   TEXT;
    v_prouni_year     INT;
    v_prouni_semester TEXT;

    v_course_group_courses TEXT[];
    v_academic_floor       NUMERIC := 50.0;
    v_user_tags             TEXT[] := '{}';
BEGIN
    -- Serialize execution for the same profile_id to prevent concurrent runs inserting duplicate matches
    PERFORM pg_advisory_xact_lock(hashtext(p_profile_id::text));

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

    -- Build user tags list combining quota types, income tags and general tags
    v_user_tags := COALESCE(v_quota_types, '{}'::TEXT[]) || ARRAY['SEM_CRITERIO_RENDA', 'AMPLA_CONCORRENCIA'];
    
    IF v_income IS NOT NULL THEN
        IF v_income <= v_salario_minimo * 1.0 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_1_SM', 'RENDA_ATE_1_5_SM', 'RENDA_ATE_2_SM', 'RENDA_ATE_4_SM', 'BAIXA_RENDA'];
        ELSIF v_income <= v_salario_minimo * 1.5 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_1_5_SM', 'RENDA_ATE_2_SM', 'RENDA_ATE_4_SM', 'BAIXA_RENDA'];
        ELSIF v_income <= v_salario_minimo * 2.0 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_2_SM', 'RENDA_ATE_4_SM'];
        ELSIF v_income <= v_salario_minimo * 4.0 THEN
            v_user_tags := v_user_tags || ARRAY['RENDA_ATE_4_SM'];
        END IF;
    END IF;

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
                       "score_decay_above_cutoff":0.3,"score_decay_below_cutoff":0.9,"academic_score_floor":50}'::jsonb;
    END IF;
    v_academic_floor := COALESCE((v_weights->>'academic_score_floor')::NUMERIC, 50.0);

    -- 4. Course group fallback
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
              v_course_interests IS NULL OR cardinality(v_course_interests) = 0
              OR
              EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                      WHERE c.course_name ILIKE '%'||ci||'%')
              OR
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
                     AND NOT EXISTS (
                         SELECT 1 FROM jsonb_array_elements(ao.concurrency_tags) AS ts
                         WHERE ts ? 'SEM_CRITERIO_RENDA'
                     )
                     AND ao.concurrency_type NOT ILIKE '%independentemente%da%renda%'
                     AND ao.concurrency_type NOT ILIKE '%independentemente%de%renda%'
                     AND ao.concurrency_type NOT ILIKE '%independente%da%renda%'
                     AND ao.concurrency_type NOT ILIKE '%independente%de%renda%'
                     AND ao.concurrency_type NOT ILIKE '%qualquer%renda%'
                     AND ao.concurrency_type NOT ILIKE '%sem%critério%de%renda%'
                     AND ao.concurrency_type NOT ILIKE '%não%declarem%ser%oriundos%de%famílias%com%renda%'
                     AND v_income IS NOT NULL AND v_income > v_salario_minimo * 1.5 THEN false
                ELSE true
            END AS meets_income,
            CASE
                WHEN ao.concurrency_tags IS NULL OR jsonb_array_length(ao.concurrency_tags) = 0 THEN false
                WHEN EXISTS (
                    SELECT 1 FROM jsonb_array_elements(ao.concurrency_tags) AS tag_set
                    WHERE NOT (
                        jsonb_array_length(tag_set) = 1 AND tag_set->>0 = 'AMPLA_CONCORRENCIA'
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM jsonb_array_elements_text(tag_set) AS tag
                        WHERE NOT (tag = ANY(v_user_tags))
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
                -- Parceiro NÃO usa pilar acadêmico (ver evaluate_partner_eligibility)
                WHEN sp.is_partner THEN NULL
                WHEN sp.weighted_enem_score IS NOT NULL AND sp.cutoff_score IS NOT NULL AND sp.cutoff_score > 0 THEN
                    GREATEST(v_academic_floor, LEAST(100.0,
                        (100.0 - CASE
                            WHEN sp.weighted_enem_score >= sp.cutoff_score THEN
                                (sp.weighted_enem_score - sp.cutoff_score) * COALESCE((v_weights->>'score_decay_above_cutoff')::NUMERIC, 0.3)
                            ELSE
                                (sp.cutoff_score - sp.weighted_enem_score) * COALESCE((v_weights->>'score_decay_below_cutoff')::NUMERIC, 0.9)
                         END)
                        * CASE WHEN v_is_treineiro_score THEN 0.85 ELSE 1.0 END))
                -- MEC sem corte OU sem ENEM → piso (informação ausente = neutro)
                ELSE v_academic_floor
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
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                                 WHERE LOWER(sa.course_name) = LOWER(ci)) THEN 100.0
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND EXISTS (SELECT 1 FROM unnest(v_course_interests) ci
                                 WHERE sa.course_name ILIKE '%'||ci||'%') THEN 85.0
                WHEN v_course_interests IS NOT NULL AND cardinality(v_course_interests) > 0
                     AND v_course_group_courses IS NOT NULL
                     AND UPPER(sa.course_name) = ANY(v_course_group_courses) THEN 70.0
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
               pe.elig AS partner_elig,
               CASE
                   -- PARCEIRO: pontua por elegibilidade (partner_forms), fora do pipeline MEC
                   WHEN sl.is_partner THEN COALESCE((pe.elig->>'score')::numeric, 100.0)
                   -- MEC: gate de renda + composição de pilares
                   WHEN NOT sl.meets_income THEN 0.0
                   ELSE LEAST(100.0, GREATEST(0.0,
                       COALESCE((v_weights->>'performance_weight')::NUMERIC,0.40)*sl.academic_score
                       + COALESCE((v_weights->>'preference_weight')::NUMERIC,0.30)*(
                           sl.shift_score*0.333 + sl.inst_program_score*0.333 + sl.course_score*0.334)
                       + COALESCE((v_weights->>'location_weight')::NUMERIC,0.20)*(
                           LEAST(100.0, sl.distance_score + sl.regional_bonus))))
               END AS base_score
        FROM scored_location sl
        LEFT JOIN LATERAL (
            SELECT public.evaluate_partner_eligibility(p_profile_id, sl.opp_id) AS elig
            WHERE sl.is_partner
        ) pe ON true
    ),

    boosted AS (
        SELECT c.*,
            CASE
                -- PARCEIRO: elegibilidade + partner_boost (lever de visibilidade configurável)
                WHEN c.is_partner THEN
                    LEAST(c.base_score*COALESCE((v_weights->>'partner_boost')::NUMERIC,1.15),
                          c.base_score+COALESCE((v_weights->>'partner_boost_cap')::NUMERIC,20.0))
                -- MEC fora de renda → 0
                WHEN NOT c.meets_income THEN 0.0
                -- MEC: base + boosts MEC-only (vagas ociosas, cota)
                ELSE c.base_score
                     + CASE WHEN c.has_vagas_ociosas THEN COALESCE((v_weights->>'idle_vacancy_boost')::NUMERIC, 5.0) ELSE 0.0 END
                     + CASE WHEN c.cota_eligible     THEN COALESCE((v_weights->>'cota_bonus')::NUMERIC,10.0)        ELSE 0.0 END
            END AS final_score,
            jsonb_build_object(
                'score_basis', CASE WHEN c.is_partner THEN 'eligibility' ELSE 'academic' END,
                'partner_eligibility', c.partner_elig,
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
                'boost_applied', c.is_partner,
                'idle_vacancy_boost_applied', c.has_vagas_ociosas AND NOT c.is_partner,
                'cota_bonus_applied', (c.cota_eligible AND c.meets_income AND NOT c.is_partner),
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
$function$;
