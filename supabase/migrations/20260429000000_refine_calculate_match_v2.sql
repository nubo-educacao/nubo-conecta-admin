-- =============================================================================
-- Migration: refine_calculate_match_v2 (Sprint 7.0)
-- Objetivos:
-- 1. Regras estritas de eligibilidade (renda per capita para Prouni e Parceiros).
-- 2. Score acadêmico comparando com nota de corte.
-- 3. Inclusão da flag meets_income no match_details.
-- 4. Criar função get_opportunities_for_user(p_profile_id) para a aba "Para Você".
-- =============================================================================

CREATE OR REPLACE FUNCTION public.calculate_match(p_profile_id UUID)
RETURNS TABLE (
    unified_opportunity_id TEXT,
    match_score NUMERIC,
    match_details JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_enem_score NUMERIC;
    v_income NUMERIC;
    v_course_interests TEXT[];
    v_quota_types TEXT[];
    v_lat NUMERIC;
    v_lon NUMERIC;
    v_weights JSONB;
BEGIN
    -- 1. Carregar preferências do perfil
    SELECT
        up.enem_score,
        up.family_income_per_capita,
        up.course_interest,
        up.quota_types,
        up.device_latitude,
        up.device_longitude
    INTO v_enem_score, v_income, v_course_interests, v_quota_types, v_lat, v_lon
    FROM public.user_preferences up
    WHERE up.user_id = p_profile_id;

    -- 2. Carregar pesos ativos (com default values se não achar)
    SELECT jsonb_object_agg(weight_key, weight_value)
    INTO v_weights
    FROM public.match_config
    WHERE is_active = true;

    IF v_weights IS NULL THEN
        v_weights := '{"enem_weight": 0.40, "income_weight": 0.30, "location_weight": 0.20, "course_interest_weight": 0.10, "partner_boost": 1.15, "partner_boost_cap": 20}'::jsonb;
    END IF;

    -- 3. Limpar matches antigos deste perfil
    DELETE FROM public.user_opportunity_matches WHERE profile_id = p_profile_id;

    -- 4. Calcular e inserir novos matches
    RETURN QUERY
    WITH raw_opportunities AS (
        SELECT 
            vo.unified_id,
            vo.type,
            vo.is_partner,
            vo.category
        FROM public.v_unified_opportunities vo
    ),
    evaluated AS (
        SELECT
            ro.unified_id,
            ro.is_partner,
            CASE 
                WHEN ro.unified_id LIKE 'mec_%' THEN substring(ro.unified_id from 5)::uuid 
                ELSE NULL 
            END AS mec_id,
            CASE 
                WHEN ro.unified_id LIKE 'partner_%' THEN substring(ro.unified_id from 9)::uuid 
                ELSE NULL 
            END AS partner_id
        FROM raw_opportunities ro
    ),
    detailed AS (
        SELECT 
            e.unified_id,
            e.is_partner,
            o.scholarship_type,
            o.cutoff_score,
            po.eligibility_criteria
        FROM evaluated e
        LEFT JOIN public.opportunities o ON e.mec_id = o.id
        LEFT JOIN public.partner_opportunities po ON e.partner_id = po.id
    ),
    scored AS (
        SELECT
            d.unified_id,
            d.is_partner,
            -- Renda check (Assumindo SM = 1412.00)
            CASE
                WHEN d.is_partner = false AND d.scholarship_type ILIKE '%Integral%' AND (v_income IS NOT NULL AND v_income > 1412.00 * 1.5) THEN false
                WHEN d.is_partner = false AND d.scholarship_type ILIKE '%Parcial%'  AND (v_income IS NOT NULL AND v_income > 1412.00 * 3.0) THEN false
                WHEN d.is_partner = true  AND d.eligibility_criteria->>'per_capita_income_limit' IS NOT NULL AND (v_income IS NOT NULL AND v_income > (d.eligibility_criteria->>'per_capita_income_limit')::numeric) THEN false
                ELSE true
            END AS meets_income,
            
            -- Academic Score
            CASE 
                WHEN v_enem_score IS NOT NULL AND d.cutoff_score IS NOT NULL AND d.cutoff_score > 0 THEN
                    LEAST(100.0, (v_enem_score / d.cutoff_score) * 100.0)
                WHEN v_enem_score IS NOT NULL AND v_enem_score > 0 THEN
                    LEAST(100.0, (v_enem_score / 700.0) * 100.0)
                ELSE 50.0
            END AS academic_score
        FROM detailed d
    ),
    final_calc AS (
        SELECT
            s.unified_id,
            s.is_partner,
            s.meets_income,
            s.academic_score,
            CASE WHEN s.meets_income THEN
                LEAST(100.00, GREATEST(0.00,
                    COALESCE((v_weights->>'enem_weight')::NUMERIC, 0.40) * s.academic_score
                    + COALESCE((v_weights->>'income_weight')::NUMERIC, 0.30) * 100.0
                    + COALESCE((v_weights->>'location_weight')::NUMERIC, 0.20) * 50.0
                    + COALESCE((v_weights->>'course_interest_weight')::NUMERIC, 0.10) * 50.0
                ))
            ELSE 0.0 END AS base_score
        FROM scored s
    ),
    boosted AS (
        SELECT
            fc.unified_id,
            CASE
                WHEN fc.is_partner AND fc.meets_income THEN
                    LEAST(
                        fc.base_score * COALESCE((v_weights->>'partner_boost')::NUMERIC, 1.15),
                        fc.base_score + COALESCE((v_weights->>'partner_boost_cap')::NUMERIC, 20.0)
                    )
                ELSE fc.base_score
            END AS final_score,
            jsonb_build_object(
                'meets_income', fc.meets_income,
                'academic_score', round(fc.academic_score, 2),
                'base_score', round(fc.base_score, 2),
                'is_partner', fc.is_partner,
                'boost_applied', fc.is_partner AND fc.meets_income
            ) AS details
        FROM final_calc fc
    )
    INSERT INTO public.user_opportunity_matches AS uom (profile_id, unified_opportunity_id, match_score, match_details)
    SELECT p_profile_id, b.unified_id, round(b.final_score, 2), b.details
    FROM boosted b
    WHERE b.final_score > 0
    RETURNING uom.unified_opportunity_id, uom.match_score, uom.match_details;
END;
$$;


-- Nova RPC para retornar as vagas ordenadas com seus matches
CREATE OR REPLACE FUNCTION public.get_opportunities_for_user(
    p_profile_id UUID,
    p_page INTEGER DEFAULT 0,
    p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
    unified_id text,
    title text,
    provider_name text,
    type text,
    category text,
    is_partner boolean,
    location text,
    badges jsonb,
    created_at timestamp with time zone,
    external_redirect_url text,
    external_redirect_enabled boolean,
    status text,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    match_score numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        vo.unified_id,
        vo.title,
        vo.provider_name,
        vo.type,
        vo.category,
        vo.is_partner,
        vo.location,
        vo.badges,
        vo.created_at,
        vo.external_redirect_url,
        vo.external_redirect_enabled,
        vo.status,
        vo.starts_at,
        vo.ends_at,
        uom.match_score
    FROM public.v_unified_opportunities vo
    JOIN public.user_opportunity_matches uom ON uom.unified_opportunity_id = vo.unified_id
    WHERE uom.profile_id = p_profile_id
    ORDER BY uom.match_score DESC NULLS LAST, vo.created_at DESC
    LIMIT p_limit OFFSET (p_page * p_limit);
END;
$$;
