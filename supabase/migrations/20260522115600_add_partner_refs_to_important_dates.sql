-- Adiciona colunas para vincular a Parceiros e Oportunidades
ALTER TABLE public.important_dates
ADD COLUMN IF NOT EXISTS partner_id UUID REFERENCES public.institutions(id) ON DELETE CASCADE,
ADD COLUMN IF NOT EXISTS opportunity_id UUID REFERENCES public.partner_opportunities(id) ON DELETE CASCADE;

-- Atualiza a função manage_important_date
CREATE OR REPLACE FUNCTION public.manage_important_date(
    p_id uuid DEFAULT NULL::uuid,
    p_title text DEFAULT NULL::text,
    p_description text DEFAULT NULL::text,
    p_start_date timestamp with time zone DEFAULT NULL::timestamp with time zone,
    p_end_date timestamp with time zone DEFAULT NULL::timestamp with time zone,
    p_type text DEFAULT NULL::text,
    p_delete boolean DEFAULT false,
    p_controls_opportunity_dates boolean DEFAULT NULL::boolean,
    p_partner_id uuid DEFAULT NULL::uuid,
    p_opportunity_id uuid DEFAULT NULL::uuid
)
RETURNS important_dates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_date public.important_dates;
BEGIN
    -- Permission check
    IF NOT EXISTS (
        SELECT 1 FROM public.user_permissions
        WHERE user_id = auth.uid()
        AND permission = 'Calendário'
    ) THEN
        RAISE EXCEPTION 'Acesso negado. Permissão insuficiente.';
    END IF;

    IF p_delete AND p_id IS NOT NULL THEN
        DELETE FROM public.important_dates WHERE id = p_id RETURNING * INTO v_date;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Data não encontrada.';
        END IF;
        RETURN v_date;

    ELSIF p_id IS NULL THEN
        INSERT INTO public.important_dates (
            title, description, start_date, end_date, type, controls_opportunity_dates, partner_id, opportunity_id
        )
        VALUES (
            p_title, p_description, p_start_date, p_end_date, p_type, COALESCE(p_controls_opportunity_dates, false), p_partner_id, p_opportunity_id
        )
        RETURNING * INTO v_date;

    ELSE
        UPDATE public.important_dates
        SET
            title = COALESCE(p_title, title),
            description = COALESCE(p_description, description),
            start_date = COALESCE(p_start_date, start_date),
            end_date = COALESCE(p_end_date, end_date),
            type = COALESCE(p_type, type),
            controls_opportunity_dates = COALESCE(p_controls_opportunity_dates, controls_opportunity_dates),
            partner_id = p_partner_id, -- Allow nullifying
            opportunity_id = p_opportunity_id -- Allow nullifying
        WHERE id = p_id
        RETURNING * INTO v_date;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Data não encontrada.';
        END IF;
    END IF;

    RETURN v_date;
END;
$function$;
