-- Migration: fix get_opportunities_for_user — colunas de corte inexistentes na view
--
-- BUG: a RPC selecionava vo.min_cutoff_score e vo.max_cutoff_score, colunas que NÃO
-- existem em v_unified_opportunities (a view expõe *_current e *_prev). A cada chamada
-- a RPC lançava "column vo.min_cutoff_score does not exist", o frontend engolia o erro
-- (services/opportunities.ts) e caía no fallback ordenado por recência — por isso a aba
-- "Para Você" exibia as oportunidades mais recentes em vez dos matches do usuário.
--
-- FIX: referenciar as colunas reais da view e alinhar a assinatura de retorno ao que o
-- frontend de fato consome (min/max_cutoff_score_current/_prev, nu_media_minima_enem_*).

DROP FUNCTION IF EXISTS public.get_opportunities_for_user(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.get_opportunities_for_user(
    p_profile_id uuid,
    p_page integer DEFAULT 0,
    p_limit integer DEFAULT 20
)
RETURNS TABLE(
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
    match_score numeric,
    match_details jsonb,
    min_cutoff_score_current numeric,
    min_cutoff_score_prev numeric,
    max_cutoff_score_current numeric,
    max_cutoff_score_prev numeric,
    nu_media_minima_enem_current numeric,
    nu_media_minima_enem_prev numeric,
    institution_cover_url text,
    opportunity_type text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
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
        uom.match_score,
        uom.match_details,
        vo.min_cutoff_score_current,
        vo.min_cutoff_score_prev,
        vo.max_cutoff_score_current,
        vo.max_cutoff_score_prev,
        vo.nu_media_minima_enem_current,
        vo.nu_media_minima_enem_prev,
        vo.institution_cover_url,
        vo.opportunity_type
    FROM public.v_unified_opportunities vo
    JOIN public.user_opportunity_matches uom ON uom.unified_opportunity_id = vo.unified_id
    WHERE uom.profile_id = p_profile_id
      AND uom.match_score > 0
    ORDER BY vo.is_partner DESC, uom.match_score DESC NULLS LAST
    LIMIT p_limit OFFSET (p_page * p_limit);
END;
$function$;
