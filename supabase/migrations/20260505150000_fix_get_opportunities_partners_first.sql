-- =============================================================================
-- Migration: get_opportunities_for_user — partners always first
--
-- Bug: partners têm match_score menor que MEC (67.84 < 73.01), então com
--      LIMIT 30 os 100 cards MEC preenchem tudo e os 4 partners nunca aparecem.
--
-- Fix: ORDER BY vo.is_partner DESC primeiro — partners sempre no topo,
--      depois MEC ordenado por match_score DESC.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_opportunities_for_user(
    p_profile_id UUID,
    p_page INTEGER DEFAULT 0,
    p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
    unified_id TEXT,
    title TEXT,
    provider_name TEXT,
    type TEXT,
    category TEXT,
    is_partner BOOLEAN,
    location TEXT,
    badges JSONB,
    created_at TIMESTAMPTZ,
    external_redirect_url TEXT,
    external_redirect_enabled BOOLEAN,
    status TEXT,
    starts_at TIMESTAMPTZ,
    ends_at TIMESTAMPTZ,
    match_score NUMERIC,
    match_details JSONB,
    min_cutoff_score NUMERIC,
    max_cutoff_score NUMERIC,
    institution_cover_url TEXT,
    opportunity_type TEXT
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
        uom.match_score,
        uom.match_details,
        vo.min_cutoff_score,
        vo.max_cutoff_score,
        vo.institution_cover_url,
        vo.opportunity_type
    FROM public.v_unified_opportunities vo
    JOIN public.user_opportunity_matches uom ON uom.unified_opportunity_id = vo.unified_id
    WHERE uom.profile_id = p_profile_id
      AND uom.match_score > 0
    ORDER BY vo.is_partner DESC, uom.match_score DESC NULLS LAST
    LIMIT p_limit OFFSET (p_page * p_limit);
END;
$$;

COMMENT ON FUNCTION public.get_opportunities_for_user IS
    'Returns unified opportunities joined with pre-calculated match scores. '
    'Partners always first (is_partner DESC), then MEC ordered by match_score DESC.';
