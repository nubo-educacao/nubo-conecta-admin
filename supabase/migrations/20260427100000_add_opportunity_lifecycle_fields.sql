-- =============================================================================
-- Migration: Sprint 6 — Campos temporais para ciclo de vida de oportunidades
-- Adiciona starts_at/ends_at em partner_opportunities e
-- controls_opportunity_dates em important_dates.
-- =============================================================================

-- 1. Campos temporais em partner_opportunities
ALTER TABLE public.partner_opportunities
  ADD COLUMN IF NOT EXISTS starts_at timestamptz,
  ADD COLUMN IF NOT EXISTS ends_at   timestamptz;

COMMENT ON COLUMN public.partner_opportunities.starts_at IS 'Inicio do periodo de inscricoes da oportunidade parceira';
COMMENT ON COLUMN public.partner_opportunities.ends_at   IS 'Fim do periodo de inscricoes da oportunidade parceira';

CREATE INDEX IF NOT EXISTS idx_partner_opp_dates
  ON public.partner_opportunities (starts_at, ends_at)
  WHERE status = 'approved';

-- 2. Flag de controle de datas MEC em important_dates
ALTER TABLE public.important_dates
  ADD COLUMN IF NOT EXISTS controls_opportunity_dates boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.important_dates.controls_opportunity_dates
  IS 'Quando true, start_date/end_date desta entrada sao usados como periodo de inscricao das oportunidades MEC do tipo correspondente (sisu/prouni)';

-- 3. Atualizar RPC manage_important_date para aceitar o novo campo
CREATE OR REPLACE FUNCTION public.manage_important_date(
    p_id UUID DEFAULT NULL,
    p_title TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL,
    p_type TEXT DEFAULT NULL,
    p_delete BOOLEAN DEFAULT FALSE,
    p_controls_opportunity_dates BOOLEAN DEFAULT NULL
)
RETURNS public.important_dates
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
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
        INSERT INTO public.important_dates (title, description, start_date, end_date, type, controls_opportunity_dates)
        VALUES (p_title, p_description, p_start_date, p_end_date, p_type, COALESCE(p_controls_opportunity_dates, false))
        RETURNING * INTO v_date;

    ELSE
        UPDATE public.important_dates
        SET
            title = COALESCE(p_title, title),
            description = COALESCE(p_description, description),
            start_date = COALESCE(p_start_date, start_date),
            end_date = COALESCE(p_end_date, end_date),
            type = COALESCE(p_type, type),
            controls_opportunity_dates = COALESCE(p_controls_opportunity_dates, controls_opportunity_dates)
        WHERE id = p_id
        RETURNING * INTO v_date;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Data não encontrada.';
        END IF;
    END IF;

    RETURN v_date;
END;
$$;
