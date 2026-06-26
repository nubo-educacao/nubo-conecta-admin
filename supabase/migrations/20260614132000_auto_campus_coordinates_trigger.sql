-- Migration: Automatic campus coordinates trigger
-- Sprint 15 — Automatically resolves and populates campus coordinates (latitude/longitude)
-- from the public.cities table when new campuses are inserted or updated (e.g., during ETL runs).

-- 1. Create trigger function to fetch coordinates from cities
CREATE OR REPLACE FUNCTION public.trg_populate_campus_coordinates()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF NEW.latitude IS NULL OR NEW.longitude IS NULL THEN
        SELECT c.latitude, c.longitude
        INTO NEW.latitude, NEW.longitude
        FROM public.cities c
        WHERE c.name = NEW.city AND c.state = NEW.state
        LIMIT 1;
    END IF;
    RETURN NEW;
END;
$$;

-- 2. Drop trigger if it exists and attach it to public.campus
DROP TRIGGER IF EXISTS before_campus_insert_update_coordinates ON public.campus;

CREATE TRIGGER before_campus_insert_update_coordinates
    BEFORE INSERT OR UPDATE ON public.campus
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_populate_campus_coordinates();

-- 3. Retroactively populate coordinates for existing campuses
UPDATE public.campus cp
SET 
    latitude = c.latitude, 
    longitude = c.longitude
FROM public.cities c
WHERE cp.city = c.name 
  AND cp.state = c.state
  AND cp.latitude IS NULL;

-- 4. Refresh materialized view to reflect populated coordinates
REFRESH MATERIALIZED VIEW public.v_unified_opportunities;
