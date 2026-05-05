-- Fix haversine_km to accept both numeric and float8 (via float8 signature)
-- This avoids "function public.haversine_km(numeric, numeric, double precision, double precision) does not exist"

DROP FUNCTION IF EXISTS public.haversine_km(numeric, numeric, numeric, numeric);

CREATE OR REPLACE FUNCTION public.haversine_km(
    lat1 FLOAT8, lon1 FLOAT8,
    lat2 FLOAT8, lon2 FLOAT8
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN lat1 IS NULL OR lon1 IS NULL OR lat2 IS NULL OR lon2 IS NULL THEN NULL
        ELSE
            (6371.0 * 2 * asin(sqrt(
                sin(radians((lat2 - lat1) / 2.0)) ^ 2
                + cos(radians(lat1)) * cos(radians(lat2))
                * sin(radians((lon2 - lon1) / 2.0)) ^ 2
            )))::numeric
    END;
$$;

COMMENT ON FUNCTION public.haversine_km IS 'Calcula a distância em KM entre dois pontos usando a fórmula de Haversine. Suporta FLOAT8/NUMERIC.';
