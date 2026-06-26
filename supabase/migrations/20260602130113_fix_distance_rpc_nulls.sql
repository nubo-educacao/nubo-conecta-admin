-- 20260602130113_fix_distance_rpc_nulls.sql
-- Fix get_unified_opportunities_by_distance to return NULL instead of 0 for missing coordinates
-- Recreates the function with the EXACT SAME OUT parameters as 20260602100000

CREATE OR REPLACE FUNCTION get_unified_opportunities_by_distance(
  p_lat DOUBLE PRECISION,
  p_long DOUBLE PRECISION
)
RETURNS TABLE (
    unified_id TEXT,
    title TEXT,
    provider_name TEXT,
    type TEXT,
    opportunity_type TEXT,
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
    min_cutoff_score NUMERIC,
    max_cutoff_score NUMERIC,
    institution_cover_url TEXT,
    nu_vagas_autorizadas TEXT,
    qt_vagas_ofertadas TEXT,
    qt_inscricao_2025 TEXT,
    vagas_ociosas_2025 INTEGER,
    institution_id UUID,
    institution_igc TEXT,
    institution_organization TEXT,
    institution_category TEXT,
    institution_site TEXT,
    eligibility_criteria JSONB,
    benefits JSONB,
    brand_color TEXT,
    weights JSONB,
    institution_acronym TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    distance_km NUMERIC
)
LANGUAGE sql
STABLE
AS $$
  SELECT 
    v.*,
    -- Calcula a distancia. Se a oportunidade for de parceiro (lat/long nulos) ou os parametros forem nulos, retorna NULL
    CASE 
      WHEN v.latitude IS NULL OR v.longitude IS NULL THEN NULL::numeric
      WHEN p_lat IS NULL OR p_long IS NULL THEN NULL::numeric
      ELSE public.haversine_km(p_lat, p_long, v.latitude, v.longitude)::numeric
    END AS distance_km
  FROM public.v_unified_opportunities v
$$;
