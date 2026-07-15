-- 20260708170000_apply_word_similarity_search.sql
--
-- Registra 20260708160000 no schema_migrations e aplica o conteúdo dela.
-- Necessário pois o schema_migrations do prod ficou desincronizado.
-- ====================================================================================

-- Registra a migration anterior no histórico
INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
VALUES ('20260708160000', 'word_similarity_search', NULL)
ON CONFLICT (version) DO NOTHING;

-- ====================================================================================
-- Atualiza search_opportunities para usar word_similarity
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.search_opportunities(p_q text)
RETURNS SETOF public.v_unified_opportunities
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT *
  FROM public.v_unified_opportunities
  WHERE word_similarity(public.f_unaccent(p_q), search_text) > 0.2;
$$;

GRANT EXECUTE ON FUNCTION public.search_opportunities(text) TO anon, authenticated, service_role;

-- ====================================================================================
-- Nova RPC: search_opportunities_by_distance
-- ====================================================================================
CREATE OR REPLACE FUNCTION public.search_opportunities_by_distance(
  p_lat  double precision,
  p_long double precision,
  p_q    text
)
RETURNS TABLE (
  unified_id                  text,
  title                       text,
  provider_name               text,
  type                        text,
  opportunity_type            text,
  category                    text,
  is_partner                  boolean,
  location                    text,
  badges                      jsonb,
  created_at                  timestamptz,
  external_redirect_url       text,
  external_redirect_enabled   boolean,
  status                      text,
  starts_at                   timestamptz,
  ends_at                     timestamptz,
  match_score                 numeric,
  institution_cover_url       text,
  nu_vagas_autorizadas        text,
  institution_id              uuid,
  institution_igc             text,
  institution_organization    text,
  institution_category        text,
  institution_site            text,
  eligibility_criteria        jsonb,
  benefits                    jsonb,
  brand_color                 text,
  weights                     jsonb,
  institution_acronym         text,
  latitude                    double precision,
  longitude                   double precision,
  min_cutoff_score_current    numeric,
  min_cutoff_score_prev       numeric,
  max_cutoff_score_current    numeric,
  max_cutoff_score_prev       numeric,
  qt_vagas_ofertadas_current  text,
  qt_vagas_ofertadas_prev     text,
  qt_inscricao_current        text,
  qt_inscricao_prev           text,
  nu_media_minima_enem_current numeric,
  nu_media_minima_enem_prev   numeric,
  vagas_ociosas_current       boolean,
  vagas_ociosas_prev          boolean,
  search_text                 text,
  distance_km                 double precision
)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    v.*,
    CASE
      WHEN v.latitude IS NOT NULL AND v.longitude IS NOT NULL
           AND p_lat IS NOT NULL AND p_long IS NOT NULL THEN
        6371.0 * acos(
          LEAST(1.0, GREATEST(-1.0,
            cos(radians(p_lat)) * cos(radians(v.latitude)) *
            cos(radians(v.longitude) - radians(p_long)) +
            sin(radians(p_lat)) * sin(radians(v.latitude))
          ))
        )
      ELSE NULL
    END AS distance_km
  FROM public.v_unified_opportunities v
  WHERE word_similarity(public.f_unaccent(p_q), v.search_text) > 0.2;
$$;

GRANT EXECUTE ON FUNCTION public.search_opportunities_by_distance(double precision, double precision, text)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
