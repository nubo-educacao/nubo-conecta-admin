-- Sprint 16.0: Priorizar oportunidades abertas no carrossel "Para Você"
DROP FUNCTION IF EXISTS public.get_opportunities_for_user(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.get_opportunities_for_user(
  p_profile_id uuid,
  p_page integer DEFAULT 0,
  p_limit integer DEFAULT 20
)
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
        vo.unified_id, vo.title, vo.provider_name, vo.type, vo.category, vo.is_partner,
        vo.location, vo.badges, vo.created_at, vo.external_redirect_url,
        vo.external_redirect_enabled, vo.status, vo.starts_at, vo.ends_at,
        uom.match_score, uom.match_details,
        vo.min_cutoff_score_current, vo.min_cutoff_score_prev,
        vo.max_cutoff_score_current, vo.max_cutoff_score_prev,
        vo.nu_media_minima_enem_current, vo.nu_media_minima_enem_prev,
        vo.institution_cover_url, vo.opportunity_type,
        vo.vagas_ociosas_current, vo.vagas_ociosas_prev
    FROM public.v_unified_opportunities vo
    JOIN public.user_opportunity_matches uom ON uom.unified_opportunity_id = vo.unified_id
    WHERE uom.profile_id = p_profile_id
      AND uom.match_score > 0
    ORDER BY
      (vo.status = 'opened') DESC,   -- Abertas primeiro
      vo.is_partner DESC,             -- Parceiros como desempate
      uom.match_score DESC NULLS LAST -- Match score final
    LIMIT p_limit OFFSET (p_page * p_limit);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_opportunities_for_user(uuid, integer, integer) TO service_role, authenticated;
