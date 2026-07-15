-- Drop the 7-parameter obsolete version of manage_important_date
DROP FUNCTION IF EXISTS public.manage_important_date(
    p_id uuid,
    p_title text,
    p_description text,
    p_start_date timestamp with time zone,
    p_end_date timestamp with time zone,
    p_type text,
    p_delete boolean
);

-- Drop the 8-parameter obsolete version of manage_important_date
DROP FUNCTION IF EXISTS public.manage_important_date(
    p_id uuid,
    p_title text,
    p_description text,
    p_start_date timestamp with time zone,
    p_end_date timestamp with time zone,
    p_type text,
    p_delete boolean,
    p_controls_opportunity_dates boolean
);
