-- 20260602132000_populate_campus_coordinates_from_cities.sql
-- Preenche as latitudes e longitudes ausentes nos campi (especialmente SISU)
-- usando a tabela de cidades (public.cities) existente.

UPDATE public.campus cp
SET 
    latitude = c.latitude, 
    longitude = c.longitude
FROM public.cities c
WHERE cp.city = c.name 
  AND cp.state = c.state
  AND cp.latitude IS NULL;

-- Como a v_unified_opportunities é uma Materialized View que lê de campus,
-- nós precisamos atualizá-la para refletir essas novas coordenadas.
REFRESH MATERIALIZED VIEW public.v_unified_opportunities;
