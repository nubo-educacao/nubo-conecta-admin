-- Syncing external_redirect_config column to partners table (matching prod)
ALTER TABLE IF EXISTS public.partners ADD COLUMN IF NOT EXISTS external_redirect_config jsonb;

-- Update manage_partner RPC to support external_redirect_config
CREATE OR REPLACE FUNCTION public.manage_partner(
    p_id uuid DEFAULT NULL,
    p_name text DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_location text DEFAULT NULL,
    p_type text DEFAULT NULL,
    p_income text DEFAULT NULL,
    p_dates jsonb DEFAULT NULL,
    p_link text DEFAULT NULL,
    p_coverimage text DEFAULT NULL,
    p_applications_open boolean DEFAULT NULL,
    p_delete boolean DEFAULT FALSE,
    p_external_redirect_config jsonb DEFAULT NULL
)
 RETURNS public.partners
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_partner public.partners;
BEGIN
    -- Permission check: Only users with 'Dashboard' permission can manage partners
    IF NOT EXISTS (
        SELECT 1 FROM public.user_permissions 
        WHERE user_id = auth.uid() 
        AND permission = 'Dashboard'
    ) THEN
        RAISE EXCEPTION 'Acesso negado. Permissão insuficiente.';
    END IF;

    IF p_delete AND p_id IS NOT NULL THEN
        DELETE FROM public.partners WHERE id = p_id RETURNING * INTO v_partner;
    ELSIF p_id IS NULL THEN
        -- Create new partner
        INSERT INTO public.partners (
            name, 
            description, 
            location, 
            type, 
            income, 
            dates, 
            link, 
            coverimage,
            applications_open,
            external_redirect_config
        )
        VALUES (
            p_name, 
            p_description, 
            p_location, 
            p_type, 
            p_income, 
            p_dates, 
            p_link, 
            p_coverimage,
            COALESCE(p_applications_open, true),
            p_external_redirect_config
        )
        RETURNING * INTO v_partner;
    ELSE
        -- Update existing partner
        UPDATE public.partners
        SET 
            name = COALESCE(p_name, name),
            description = COALESCE(p_description, description),
            location = COALESCE(p_location, location),
            type = COALESCE(p_type, type),
            income = COALESCE(p_income, income),
            dates = COALESCE(p_dates, dates),
            link = COALESCE(p_link, link),
            coverimage = COALESCE(p_coverimage, coverimage),
            applications_open = COALESCE(p_applications_open, applications_open),
            external_redirect_config = COALESCE(p_external_redirect_config, external_redirect_config),
            updated_at = NOW()
        WHERE id = p_id
        RETURNING * INTO v_partner;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Parceiro não encontrado.';
        END IF;
    END IF;

    RETURN v_partner;
END;
$function$;
