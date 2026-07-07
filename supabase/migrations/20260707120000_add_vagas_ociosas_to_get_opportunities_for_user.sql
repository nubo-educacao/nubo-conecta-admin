-- 20260707120000_add_vagas_ociosas_to_get_opportunities_for_user.sql
-- get_opportunities_for_user (fonte de dado da tela "Seus Matches"/para-você) nunca
-- selecionava vagas_ociosas_current/vagas_ociosas_prev de v_unified_opportunities, mesmo
-- essas colunas existindo na view e sendo consumidas pelo OpportunityCard/SisuProuniCard.
-- Resultado: a tag "Vagas Ociosas" nunca aparecia nos cards de match, independente do dado.
-- Reproduz a definição integralmente, apenas adicionando as duas colunas na assinatura e no SELECT.
-- CREATE OR REPLACE não permite mudar o RETURNS TABLE (conjunto de colunas) — DROP explícito primeiro.

DROP FUNCTION IF EXISTS public.get_opportunities_for_user(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.get_opportunities_for_user(p_profile_id uuid, p_page integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS TABLE(
   unified_id text, title text, provider_name text, type text, category text, is_partner boolean,
   location text, badges jsonb, created_at timestamp with time zone, external_redirect_url text,
   external_redirect_enabled boolean, status text, starts_at timestamp with time zone, ends_at timestamp with time zone,
   match_score numeric, match_details jsonb, min_cutoff_score_current numeric, min_cutoff_score_prev numeric,
   max_cutoff_score_current numeric, max_cutoff_score_prev numeric, nu_media_minima_enem_current numeric,
   nu_media_minima_enem_prev numeric, institution_cover_url text, opportunity_type text,
   vagas_ociosas_current boolean, vagas_ociosas_prev boolean
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
        vo.opportunity_type,
        vo.vagas_ociosas_current,
        vo.vagas_ociosas_prev
    FROM public.v_unified_opportunities vo
    JOIN public.user_opportunity_matches uom ON uom.unified_opportunity_id = vo.unified_id
    WHERE uom.profile_id = p_profile_id
      AND uom.match_score > 0
    ORDER BY vo.is_partner DESC, uom.match_score DESC NULLS LAST
    LIMIT p_limit OFFSET (p_page * p_limit);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_opportunities_for_user(uuid, integer, integer) TO service_role, authenticated;
