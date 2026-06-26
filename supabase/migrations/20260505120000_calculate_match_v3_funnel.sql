-- =============================================================================
-- Migration: calculate_match V3 — Funnel + Partners Always (Sprint 10)
--
-- Architectural changes from previous version:
--   1. Asymmetric funnel: MEC goes through 4 preference filters; Partners bypass all.
--   2. MEC fallback when no filters declared:
--        a) Location available → haversine ≤ 500 km pre-filter
--        b) No location        → LIMIT 2000 random sample (avoids 148k full-scan)
--   3. Two separate INSERTs:
--        • MEC: TOP 100 by final_score
--        • Partners: ALL approved, always (no LIMIT)
--   4. Function now RETURNS VOID (results materialised in user_opportunity_matches)
--
-- BDD coverage:
--   ✓ MEC funnel (scenario 1)
--   ✓ Partners always (scenario 2)
--   ✓ TOP 100 MEC + all partners persisted (scenario 3)
--   ✓ Funnel fallback — location / sample (scenario 4)
--   ✓ Edge Function error handling left unchanged (scenario 5 — see edge function)
-- =============================================================================

-- Drop previous signature (returned TABLE)
DROP FUNCTION IF EXISTS public.calculate_match(UUID);

-- =============================================================================
-- RPC: calculate_match V3 — Funnel + Asymmetric INSERT
-- =============================================================================
CREATE OR REPLACE FUNCTION public.calculate_match(p_profile_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    -- User preferences
    v_income               NUMERIC;
    v_course_interests     TEXT[];
    v_preferred_shifts     TEXT[];
    v_university_preference TEXT;
    v_program_preference   TEXT;
    v_state_preference     TEXT;
    v_location_preference  TEXT;
    v_lat                  NUMERIC;
    v_lon                  NUMERIC;

    -- ENEM scores (best year, granular)
    v_nota_linguagens       NUMERIC;
    v_nota_ciencias_humanas NUMERIC;
    v_nota_ciencias_natureza NUMERIC;
    v_nota_matematica       NUMERIC;
    v_nota_redacao          NUMERIC;
    v_enem_avg              NUMERIC;
    v_has_enem              BOOLEAN := false;

    -- Config
    v_weights              JSONB;
    v_enem_window_sisu     INT     := 3;
    v_salario_minimo       NUMERIC := 1518.00;   -- 2025 value

    -- Funnel flags
    v_has_funnel_filters   BOOLEAN;
BEGIN
    -- ─────────────────────────────────────────────────────────────────────────
    -- 1. Load user preferences
    -- ─────────────────────────────────────────────────────────────────────────
    SELECT
        up.family_income_per_capita,
        up.course_interest,
        up.preferred_shifts,
        up.university_preference,
        up.program_preference,
        up.state_preference,
        up.location_preference,
        up.device_latitude,
        up.device_longitude
    INTO
        v_income, v_course_interests, v_preferred_shifts,
        v_university_preference, v_program_preference,
        v_state_preference, v_location_preference,
        v_lat, v_lon
    FROM public.user_preferences up
    WHERE up.user_id = p_profile_id;

    -- ─────────────────────────────────────────────────────────────────────────
    -- 2. Load best ENEM scores (highest simple average within last 3 years)
    -- ─────────────────────────────────────────────────────────────────────────
    SELECT
        ues.nota_linguagens,
        ues.nota_ciencias_humanas,
        ues.nota_ciencias_natureza,
        ues.nota_matematica,
        ues.nota_redacao
    INTO
        v_nota_linguagens, v_nota_ciencias_humanas,
        v_nota_ciencias_natureza, v_nota_matematica, v_nota_redacao
    FROM public.user_enem_scores ues
    WHERE ues.user_id = p_profile_id
      AND ues.year >= (EXTRACT(YEAR FROM CURRENT_DATE)::INT - v_enem_window_sisu)
    ORDER BY (
        COALESCE(ues.nota_linguagens, 0) + COALESCE(ues.nota_ciencias_humanas, 0) +
        COALESCE(ues.nota_ciencias_natureza, 0) + COALESCE(ues.nota_matematica, 0) +
        COALESCE(ues.nota_redacao, 0)
    ) DESC
    LIMIT 1;

    IF v_nota_linguagens IS NOT NULL THEN
        v_has_enem := true;
        v_enem_avg := (
            COALESCE(v_nota_linguagens, 0) + COALESCE(v_nota_ciencias_humanas, 0) +
            COALESCE(v_nota_ciencias_natureza, 0) + COALESCE(v_nota_matematica, 0) +
            COALESCE(v_nota_redacao, 0)
        ) / 5.0;
    END IF;

    -- ─────────────────────────────────────────────────────────────────────────
    -- 3. Load match_config weights (with sensible defaults)
    -- ─────────────────────────────────────────────────────────────────────────
    SELECT jsonb_object_agg(weight_key, weight_value)
    INTO v_weights
    FROM public.match_config
    WHERE is_active = true;

    IF v_weights IS NULL THEN
        v_weights := '{
            "performance_weight": 0.40,
            "preference_weight": 0.30,
            "location_weight": 0.20,
            "partner_boost": 1.15,
            "partner_boost_cap": 20,
            "idle_vacancy_boost": 5
        }'::jsonb;
    END IF;

    -- ─────────────────────────────────────────────────────────────────────────
    -- 4. Determine whether any MEC funnel filter is active
    --    Partners are ALWAYS included regardless of this flag.
    -- ─────────────────────────────────────────────────────────────────────────
    v_has_funnel_filters := (
        (v_program_preference IS NOT NULL AND v_program_preference != 'indiferente') OR
        (v_course_interests   IS NOT NULL AND cardinality(v_course_interests)   > 0) OR
        v_state_preference    IS NOT NULL OR
        (v_preferred_shifts   IS NOT NULL AND cardinality(v_preferred_shifts)   > 0)
    );

    -- ─────────────────────────────────────────────────────────────────────────
    -- 5. Clear old matches for this profile
    -- ─────────────────────────────────────────────────────────────────────────
    DELETE FROM public.user_opportunity_matches WHERE profile_id = p_profile_id;

    -- ─────────────────────────────────────────────────────────────────────────
    -- 6. Score all candidates and persist results (two separate INSERTs)
    --
    --    MEC path through the funnel:
    --      a) Filters active → apply 4-filter funnel (program/course/state/shift)
    --      b) No filters, has location → haversine ≤ 500 km pre-filter
    --      c) No filters, no location → random sample of 2000 rows
    --
    --    Partners path: always ALL approved rows, no funnel applied.
    -- ─────────────────────────────────────────────────────────────────────────
    WITH

    -- ── MEC candidates (asymmetric funnel) ──────────────────────────────────
    mec_funnel AS (
        -- Path A: funnel filters active
        SELECT
            o.id AS opp_id,
            'mec_' || o.id::text AS unified_id,
            o.course_id,
            c.course_name,
            o.opportunity_type,
            o.scholarship_type,
            o.concurrency_type,
            o.cutoff_score,
            o.shift,
            false AS is_partner,
            cp.latitude AS campus_lat,
            cp.longitude AS campus_lon,
            cp.state AS campus_state,
            cp.city AS campus_city,
            i.id AS institution_id,
            sv.peso_linguagens,
            sv.peso_ciencias_humanas,
            sv.peso_ciencias_natureza,
            sv.peso_matematica,
            sv.peso_redacao,
            sv.vagas_ociosas_2025,
            NULL::jsonb AS eligibility_criteria
        FROM public.opportunities o
        JOIN public.courses c       ON c.id = o.course_id
        JOIN public.campus cp       ON cp.id = c.campus_id
        JOIN public.institutions i  ON i.id = cp.institution_id
        LEFT JOIN public.opportunitiessisuvacancies sv ON sv.opportunity_id = o.id
        WHERE v_has_funnel_filters
          AND o.semester = '1'
          AND (
              (o.opportunity_type = 'sisu'   AND o.year = 2026) OR
              (o.opportunity_type = 'prouni' AND o.year = 2025)
          )
          -- Filter 1: Program preference
          AND (
              v_program_preference IS NULL OR v_program_preference = 'indiferente'
              OR o.opportunity_type = v_program_preference
          )
          -- Filter 2: Course interest
          AND (
              v_course_interests IS NULL OR cardinality(v_course_interests) = 0
              OR EXISTS (
                  SELECT 1 FROM unnest(v_course_interests) ci
                  WHERE c.course_name ILIKE '%' || ci || '%'
              )
          )
          -- Filter 3: State preference
          AND (v_state_preference IS NULL OR cp.state = v_state_preference)
          -- Filter 4: Shift preference
          AND (
              v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts) = 0
              OR o.shift = ANY(v_preferred_shifts)
          )

        UNION ALL

        -- Path B: no filters, has location → haversine pre-filter (≤ 500 km)
        SELECT
            o.id AS opp_id,
            'mec_' || o.id::text AS unified_id,
            o.course_id,
            c.course_name,
            o.opportunity_type,
            o.scholarship_type,
            o.concurrency_type,
            o.cutoff_score,
            o.shift,
            false AS is_partner,
            cp.latitude AS campus_lat,
            cp.longitude AS campus_lon,
            cp.state AS campus_state,
            cp.city AS campus_city,
            i.id AS institution_id,
            sv.peso_linguagens,
            sv.peso_ciencias_humanas,
            sv.peso_ciencias_natureza,
            sv.peso_matematica,
            sv.peso_redacao,
            sv.vagas_ociosas_2025,
            NULL::jsonb AS eligibility_criteria
        FROM public.opportunities o
        JOIN public.courses c       ON c.id = o.course_id
        JOIN public.campus cp       ON cp.id = c.campus_id
        JOIN public.institutions i  ON i.id = cp.institution_id
        LEFT JOIN public.opportunitiessisuvacancies sv ON sv.opportunity_id = o.id
        WHERE NOT v_has_funnel_filters
          AND v_lat IS NOT NULL AND v_lon IS NOT NULL
          AND cp.latitude IS NOT NULL AND cp.longitude IS NOT NULL
          AND o.semester = '1'
          AND (
              (o.opportunity_type = 'sisu'   AND o.year = 2026) OR
              (o.opportunity_type = 'prouni' AND o.year = 2025)
          )
          AND public.haversine_km(v_lat, v_lon, cp.latitude, cp.longitude) <= 500

        UNION ALL

        -- Path C: no filters, no location → random sample of 2000 rows
        SELECT * FROM (
            SELECT
                o.id AS opp_id,
                'mec_' || o.id::text AS unified_id,
                o.course_id,
                c.course_name,
                o.opportunity_type,
                o.scholarship_type,
                o.concurrency_type,
                o.cutoff_score,
                o.shift,
                false AS is_partner,
                cp.latitude AS campus_lat,
                cp.longitude AS campus_lon,
                cp.state AS campus_state,
                cp.city AS campus_city,
                i.id AS institution_id,
                sv.peso_linguagens,
                sv.peso_ciencias_humanas,
                sv.peso_ciencias_natureza,
                sv.peso_matematica,
                sv.peso_redacao,
                sv.vagas_ociosas_2025,
                NULL::jsonb AS eligibility_criteria
            FROM public.opportunities o
            JOIN public.courses c       ON c.id = o.course_id
            JOIN public.campus cp       ON cp.id = c.campus_id
            JOIN public.institutions i  ON i.id = cp.institution_id
            LEFT JOIN public.opportunitiessisuvacancies sv ON sv.opportunity_id = o.id
            WHERE NOT v_has_funnel_filters
              AND (v_lat IS NULL OR v_lon IS NULL)
              AND o.semester = '1'
              AND (
                  (o.opportunity_type = 'sisu'   AND o.year = 2026) OR
                  (o.opportunity_type = 'prouni' AND o.year = 2025)
              )
            ORDER BY RANDOM()
            LIMIT 2000
        ) sampled
    ),

    -- ── All candidates: funnel-filtered MEC + always-all Partners ───────────
    all_opportunities AS (
        SELECT * FROM mec_funnel

        UNION ALL

        -- Partners: always ALL approved, no funnel
        SELECT
            po.id AS opp_id,
            'partner_' || po.id::text AS unified_id,
            NULL::uuid AS course_id,
            po.name AS course_name,
            'partner' AS opportunity_type,
            NULL AS scholarship_type,
            NULL AS concurrency_type,
            NULL::numeric AS cutoff_score,
            NULL AS shift,
            true AS is_partner,
            NULL::numeric AS campus_lat,
            NULL::numeric AS campus_lon,
            NULL AS campus_state,
            NULL AS campus_city,
            po.institution_id,
            NULL AS peso_linguagens,
            NULL AS peso_ciencias_humanas,
            NULL AS peso_ciencias_natureza,
            NULL AS peso_matematica,
            NULL AS peso_redacao,
            NULL::integer AS vagas_ociosas_2025,
            po.eligibility_criteria
        FROM public.partner_opportunities po
        WHERE po.status = 'approved'
    ),

    -- ── Pilar 1: Performance & Elegibilidade (40%) ──────────────────────────
    scored_performance AS (
        SELECT
            ao.*,
            CASE
                WHEN ao.opportunity_type = 'prouni'
                     AND ao.scholarship_type ILIKE '%Integral%'
                     AND v_income IS NOT NULL
                     AND v_income > v_salario_minimo * 1.5
                THEN false
                WHEN ao.opportunity_type = 'prouni'
                     AND ao.scholarship_type ILIKE '%Parcial%'
                     AND v_income IS NOT NULL
                     AND v_income > v_salario_minimo * 3.0
                THEN false
                WHEN ao.opportunity_type = 'sisu'
                     AND ao.concurrency_type ILIKE '%renda%'
                     AND v_income IS NOT NULL
                     AND v_income > v_salario_minimo * 1.5
                THEN false
                WHEN ao.is_partner
                     AND ao.eligibility_criteria->>'per_capita_income_limit' IS NOT NULL
                     AND v_income IS NOT NULL
                     AND v_income > (ao.eligibility_criteria->>'per_capita_income_limit')::numeric
                THEN false
                ELSE true
            END AS meets_income,
            CASE
                WHEN v_has_enem AND ao.peso_linguagens IS NOT NULL THEN
                    (
                        COALESCE(v_nota_linguagens, 0)        * COALESCE(ao.peso_linguagens::numeric, 1) +
                        COALESCE(v_nota_ciencias_humanas, 0)  * COALESCE(ao.peso_ciencias_humanas::numeric, 1) +
                        COALESCE(v_nota_ciencias_natureza, 0) * COALESCE(ao.peso_ciencias_natureza::numeric, 1) +
                        COALESCE(v_nota_matematica, 0)        * COALESCE(ao.peso_matematica::numeric, 1) +
                        COALESCE(v_nota_redacao, 0)           * COALESCE(ao.peso_redacao::numeric, 1)
                    ) / NULLIF(
                        COALESCE(ao.peso_linguagens::numeric, 1) +
                        COALESCE(ao.peso_ciencias_humanas::numeric, 1) +
                        COALESCE(ao.peso_ciencias_natureza::numeric, 1) +
                        COALESCE(ao.peso_matematica::numeric, 1) +
                        COALESCE(ao.peso_redacao::numeric, 1),
                        0
                    )
                WHEN v_has_enem THEN v_enem_avg
                ELSE NULL
            END AS weighted_enem_score
        FROM all_opportunities ao
    ),

    scored_academic AS (
        SELECT
            sp.*,
            CASE
                WHEN sp.weighted_enem_score IS NOT NULL AND sp.cutoff_score IS NOT NULL AND sp.cutoff_score > 0 THEN
                    GREATEST(0.0, LEAST(100.0,
                        100.0 - GREATEST(0.0, sp.cutoff_score - sp.weighted_enem_score) * 0.5
                    ))
                WHEN sp.weighted_enem_score IS NOT NULL THEN
                    LEAST(100.0, (sp.weighted_enem_score / 700.0) * 100.0)
                ELSE 50.0
            END AS academic_score
        FROM scored_performance sp
    ),

    -- ── Pilar 2: Alinhamento de Preferências (30%) ──────────────────────────
    scored_preferences AS (
        SELECT
            sa.*,
            CASE
                WHEN v_preferred_shifts IS NULL OR cardinality(v_preferred_shifts) = 0 THEN 50.0
                WHEN sa.shift IS NULL THEN 50.0
                WHEN sa.shift = ANY(v_preferred_shifts) THEN 100.0
                ELSE 0.0
            END AS shift_score,
            CASE
                WHEN v_university_preference IS NULL OR v_university_preference = 'indiferente' THEN 50.0
                WHEN v_university_preference = 'publica' AND sa.opportunity_type = 'sisu' THEN 100.0
                WHEN v_university_preference = 'privada' AND sa.opportunity_type IN ('prouni', 'partner') THEN 100.0
                ELSE 20.0
            END +
            CASE
                WHEN v_program_preference IS NULL OR v_program_preference = 'indiferente' THEN 50.0
                WHEN v_program_preference = 'sisu'   AND sa.opportunity_type = 'sisu'   THEN 100.0
                WHEN v_program_preference = 'prouni' AND sa.opportunity_type = 'prouni' THEN 100.0
                ELSE 20.0
            END AS inst_program_score_raw,
            CASE
                WHEN v_course_interests IS NULL OR cardinality(v_course_interests) = 0 THEN 50.0
                WHEN EXISTS (
                    SELECT 1 FROM unnest(v_course_interests) ci
                    WHERE sa.course_name ILIKE '%' || ci || '%'
                ) THEN 100.0
                ELSE 10.0
            END AS course_score
        FROM scored_academic sa
    ),

    -- ── Pilar 3: Localização & Mobilidade (20%) ─────────────────────────────
    scored_location AS (
        SELECT
            sp.*,
            LEAST(100.0, sp.inst_program_score_raw / 2.0) AS inst_program_score,
            CASE
                WHEN v_lat IS NOT NULL AND v_lon IS NOT NULL
                     AND sp.campus_lat IS NOT NULL AND sp.campus_lon IS NOT NULL THEN
                    GREATEST(0.0, 100.0 - public.haversine_km(v_lat, v_lon, sp.campus_lat, sp.campus_lon) * 0.5)
                ELSE 40.0
            END AS distance_score,
            CASE
                WHEN v_state_preference IS NOT NULL AND sp.campus_state IS NOT NULL
                     AND LOWER(sp.campus_state) = LOWER(v_state_preference) THEN 30.0
                WHEN v_location_preference IS NOT NULL AND sp.campus_city IS NOT NULL
                     AND LOWER(sp.campus_city) ILIKE '%' || LOWER(v_location_preference) || '%' THEN 30.0
                ELSE 0.0
            END AS regional_bonus
        FROM scored_preferences sp
    ),

    -- ── Composite Score ──────────────────────────────────────────────────────
    composite AS (
        SELECT
            sl.unified_id,
            sl.course_id,
            sl.course_name,
            sl.is_partner,
            sl.meets_income,
            sl.academic_score,
            sl.shift_score,
            sl.inst_program_score,
            sl.course_score,
            sl.distance_score,
            sl.regional_bonus,
            sl.weighted_enem_score,
            sl.cutoff_score,
            sl.vagas_ociosas_2025,
            sl.opportunity_type,
            CASE WHEN sl.meets_income THEN
                LEAST(100.0, GREATEST(0.0,
                    COALESCE((v_weights->>'performance_weight')::NUMERIC, 0.40) * sl.academic_score
                    + COALESCE((v_weights->>'preference_weight')::NUMERIC, 0.30) * (
                        (sl.shift_score * 0.333) + (sl.inst_program_score * 0.333) + (sl.course_score * 0.334)
                    )
                    + COALESCE((v_weights->>'location_weight')::NUMERIC, 0.20) * (
                        LEAST(100.0, sl.distance_score + sl.regional_bonus)
                    )
                ))
            ELSE 0.0
            END AS base_score
        FROM scored_location sl
    ),

    -- ── Pilar 4: Boosts ──────────────────────────────────────────────────────
    boosted AS (
        SELECT
            c.unified_id,
            c.course_id,
            c.is_partner,
            c.meets_income,
            c.base_score,
            c.opportunity_type,
            c.academic_score,
            c.weighted_enem_score,
            c.cutoff_score,
            c.shift_score,
            c.inst_program_score,
            c.course_score,
            c.distance_score,
            c.regional_bonus,
            c.vagas_ociosas_2025,
            CASE
                WHEN NOT c.meets_income THEN 0.0
                WHEN c.is_partner THEN
                    LEAST(
                        c.base_score * COALESCE((v_weights->>'partner_boost')::NUMERIC, 1.15),
                        c.base_score + COALESCE((v_weights->>'partner_boost_cap')::NUMERIC, 20.0)
                    )
                ELSE c.base_score
            END
            + CASE
                WHEN c.vagas_ociosas_2025 IS NOT NULL AND c.vagas_ociosas_2025 > 0 AND c.meets_income THEN
                    LEAST(COALESCE((v_weights->>'idle_vacancy_boost')::NUMERIC, 5.0),
                          c.vagas_ociosas_2025::NUMERIC * 0.5)
                ELSE 0.0
            END AS final_score,
            jsonb_build_object(
                'meets_income',            c.meets_income,
                'academic_score',          round(c.academic_score, 2),
                'weighted_enem_score',     round(COALESCE(c.weighted_enem_score, 0), 2),
                'cutoff_score',            COALESCE(c.cutoff_score, 0),
                'shift_score',             round(c.shift_score, 2),
                'inst_program_score',      round(c.inst_program_score, 2),
                'course_score',            round(c.course_score, 2),
                'distance_score',          round(c.distance_score, 2),
                'regional_bonus',          round(c.regional_bonus, 2),
                'base_score',              round(c.base_score, 2),
                'is_partner',              c.is_partner,
                'boost_applied',           c.is_partner AND c.meets_income,
                'idle_vacancy_boost_applied', (c.vagas_ociosas_2025 IS NOT NULL AND c.vagas_ociosas_2025 > 0),
                'opportunity_type',        c.opportunity_type
            ) AS details
        FROM composite c
    ),

    -- ── Aggregate: MAX score per course (or per partner opportunity) ─────────
    course_best AS (
        SELECT DISTINCT ON (COALESCE(b.course_id::text, b.unified_id))
            b.unified_id,
            b.is_partner,
            LEAST(100.0, round(b.final_score, 2)) AS final_score,
            b.details
        FROM boosted b
        ORDER BY COALESCE(b.course_id::text, b.unified_id), b.final_score DESC
    ),

    -- ── INSERT 1: TOP 100 MEC only ───────────────────────────────────────────
    mec_insert AS (
        INSERT INTO public.user_opportunity_matches
            (profile_id, unified_opportunity_id, match_score, match_details)
        SELECT p_profile_id, cb.unified_id, cb.final_score, cb.details
        FROM course_best cb
        WHERE cb.is_partner = false
        ORDER BY cb.final_score DESC
        LIMIT 100
        RETURNING unified_opportunity_id
    ),

    -- ── INSERT 2: ALL approved partners (no LIMIT) ───────────────────────────
    partner_insert AS (
        INSERT INTO public.user_opportunity_matches
            (profile_id, unified_opportunity_id, match_score, match_details)
        SELECT p_profile_id, cb.unified_id, cb.final_score, cb.details
        FROM course_best cb
        WHERE cb.is_partner = true
        RETURNING unified_opportunity_id
    )

    -- Terminate the CTE chain (required when using data-modifying CTEs)
    SELECT 1
    FROM mec_insert, partner_insert
    LIMIT 0;

END;
$$;

COMMENT ON FUNCTION public.calculate_match IS
    'V3 Funnel: MEC candidates pass through 4-filter funnel (program/course/state/shift) or '
    'location/sample fallback. Partners always included. Persists TOP 100 MEC + ALL partners '
    'into user_opportunity_matches. Returns VOID — edge function handles match_status updates.';
