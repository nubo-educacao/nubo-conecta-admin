-- 20260409100000_fix_calculate_match_ambiguity.sql
-- BUG-005: Resolve "column reference unified_opportunity_id is ambiguous"
--
-- Causa-raiz: a cláusula RETURNING da função usava `unified_opportunity_id` sem qualificar,
-- e o PostgreSQL não conseguia distinguir entre o OUT parameter (RETURNS TABLE) e a
-- coluna real de `user_opportunity_matches`. Fix: alias da tabela INSERT AS uom.

CREATE OR REPLACE FUNCTION public.calculate_match(p_profile_id UUID)
RETURNS TABLE (
    unified_opportunity_id TEXT,
    match_score NUMERIC(5,2),
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

    -- 2. Carregar pesos ativos
    SELECT jsonb_object_agg(weight_key, weight_value)
    INTO v_weights
    FROM public.match_config
    WHERE is_active = true;

    -- 3. Limpar matches antigos deste perfil
    DELETE FROM public.user_opportunity_matches WHERE profile_id = p_profile_id;

    -- 4. Calcular e inserir novos matches
    RETURN QUERY
    WITH scored AS (
        SELECT
            vo.unified_id,
            -- Score base: composição ponderada dos fatores
            LEAST(100.00, GREATEST(0.00,
                -- Componente ENEM (comparação com nota de corte quando disponível)
                COALESCE((v_weights->>'enem_weight')::NUMERIC, 0.35) *
                    CASE WHEN v_enem_score IS NOT NULL AND v_enem_score > 0 THEN
                        LEAST(100, (v_enem_score / NULLIF(700, 0)) * 100)
                    ELSE 50 END
                +
                -- Componente Renda
                COALESCE((v_weights->>'income_weight')::NUMERIC, 0.20) *
                    CASE WHEN v_income IS NOT NULL THEN 70 ELSE 50 END
                +
                -- Componente Área de Interesse
                COALESCE((v_weights->>'course_interest_weight')::NUMERIC, 0.20) *
                    CASE WHEN v_course_interests IS NOT NULL AND array_length(v_course_interests, 1) > 0 THEN 80 ELSE 40 END
                +
                -- Componente Localização
                COALESCE((v_weights->>'location_weight')::NUMERIC, 0.15) * 50
                +
                -- Componente Cotas
                COALESCE((v_weights->>'quota_weight')::NUMERIC, 0.10) *
                    CASE WHEN v_quota_types IS NOT NULL AND array_length(v_quota_types, 1) > 0 THEN 75 ELSE 50 END
            )) AS base_score,
            vo.is_partner
        FROM public.v_unified_opportunities vo
    ),
    boosted AS (
        SELECT
            s.unified_id,
            CASE
                WHEN s.is_partner THEN
                    LEAST(
                        s.base_score * COALESCE((v_weights->>'partner_boost')::NUMERIC, 1.15),
                        s.base_score + COALESCE((v_weights->>'partner_boost_cap')::NUMERIC, 20.0)
                    )
                ELSE s.base_score
            END AS final_score,
            jsonb_build_object(
                'base_score', round(s.base_score, 2),
                'is_partner', s.is_partner,
                'boost_applied', s.is_partner
            ) AS details
        FROM scored s
    )
    -- FIX BUG-005: alias `uom` resolve ambiguidade entre OUT param e coluna da tabela
    INSERT INTO public.user_opportunity_matches AS uom (profile_id, unified_opportunity_id, match_score, match_details)
    SELECT p_profile_id, b.unified_id, round(b.final_score, 2), b.details
    FROM boosted b
    RETURNING uom.unified_opportunity_id, uom.match_score, uom.match_details;
END;
$$;

COMMENT ON FUNCTION public.calculate_match IS 'RPC: Calcula match scores para um perfil contra v_unified_opportunities. Limpa e regenera todo o set de matches. (BUG-005 fix: RETURNING qualificado com alias de tabela)';
