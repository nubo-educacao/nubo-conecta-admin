-- =============================================================================
-- Migration: search_opportunities usando translate() — SEM extensões
-- translate() é built-in no PostgreSQL — funciona sempre, sem schema issues
-- =============================================================================

-- Helper: remove acentos usando translate() nativo do PostgreSQL
CREATE OR REPLACE FUNCTION public.f_unaccent(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT translate(
    lower(p_text),
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
    'aaaaaeeeeiiiioooooouuuucnaaaaaeeeeiiiioooooouuuucn'
  );
$$;

GRANT EXECUTE ON FUNCTION public.f_unaccent(text) TO anon, authenticated, service_role;

-- RPC de busca accent-insensitive
CREATE OR REPLACE FUNCTION public.search_opportunities(p_q text)
RETURNS SETOF public.v_unified_opportunities
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT *
  FROM public.v_unified_opportunities
  WHERE
    public.f_unaccent(title) LIKE '%' || public.f_unaccent(p_q) || '%'
    OR public.f_unaccent(provider_name) LIKE '%' || public.f_unaccent(p_q) || '%'
    OR public.f_unaccent(location) LIKE '%' || public.f_unaccent(p_q) || '%';
$$;

GRANT EXECUTE ON FUNCTION public.search_opportunities(text) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
