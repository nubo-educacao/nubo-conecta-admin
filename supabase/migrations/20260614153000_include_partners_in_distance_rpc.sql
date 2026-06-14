-- Migration: Include partners in distance-based opportunities search
-- Partner opportunities do not have physical location coordinates, but should be returned.

CREATE OR REPLACE FUNCTION public.get_unified_opportunities_by_distance(
  p_lat double precision,
  p_long double precision
)
RETURNS TABLE (
    unified_id text, title text, provider_name text, type text, opportunity_type text,
    category text, is_partner boolean, location text, badges jsonb, created_at timestamp with time zone,
    external_redirect_url text, external_redirect_enabled boolean, status text,
    starts_at timestamp with time zone, ends_at timestamp with time zone, match_score numeric, institution_cover_url text,
    nu_vagas_autorizadas text, institution_id uuid, institution_igc text,
    institution_organization text, institution_category text, institution_site text,
    eligibility_criteria jsonb, benefits jsonb, brand_color text, weights jsonb,
    institution_acronym text, latitude double precision, longitude double precision,
    min_cutoff_score_current numeric, min_cutoff_score_prev numeric,
    max_cutoff_score_current numeric, max_cutoff_score_prev numeric,
    qt_vagas_ofertadas_current text, qt_vagas_ofertadas_prev text,
    qt_inscricao_current text, qt_inscricao_prev text,
    nu_media_minima_enem_current numeric, nu_media_minima_enem_prev numeric,
    vagas_ociosas_current boolean, vagas_ociosas_prev boolean,
    distance_km numeric
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    v.unified_id, v.title, v.provider_name, v.type, v.opportunity_type,
    v.category, v.is_partner, v.location, v.badges, v.created_at,
    v.external_redirect_url, v.external_redirect_enabled, v.status,
    v.starts_at, v.ends_at, v.match_score, v.institution_cover_url,
    v.nu_vagas_autorizadas, v.institution_id, v.institution_igc,
    v.institution_organization, v.institution_category, v.institution_site,
    v.eligibility_criteria, v.benefits, v.brand_color, v.weights,
    v.institution_acronym, v.latitude, v.longitude,
    v.min_cutoff_score_current, v.min_cutoff_score_prev,
    v.max_cutoff_score_current, v.max_cutoff_score_prev,
    v.qt_vagas_ofertadas_current, v.qt_vagas_ofertadas_prev,
    v.qt_inscricao_current, v.qt_inscricao_prev,
    v.nu_media_minima_enem_current, v.nu_media_minima_enem_prev,
    v.vagas_ociosas_current, v.vagas_ociosas_prev,
    -- Distance logic (Earth distance in KM, return null if no coords)
    (CASE 
      WHEN v.latitude IS NOT NULL AND v.longitude IS NOT NULL 
      THEN (6371 * acos(
        cos(radians(p_lat)) * cos(radians(v.latitude)) *
        cos(radians(v.longitude) - radians(p_long)) +
        sin(radians(p_lat)) * sin(radians(v.latitude))
      ))
      ELSE NULL
    END)::NUMERIC AS distance_km
  FROM public.v_unified_opportunities v
  WHERE (v.latitude IS NOT NULL AND v.longitude IS NOT NULL) OR v.is_partner = true
  ORDER BY distance_km ASC;
$$;
