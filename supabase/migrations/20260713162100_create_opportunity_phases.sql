-- Migration: create opportunity_phases table and link to student_applications
CREATE TABLE IF NOT EXISTS public.opportunity_phases (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  opportunity_id UUID      NOT NULL REFERENCES public.partner_opportunities(id) ON DELETE CASCADE,
  name         VARCHAR(100) NOT NULL,
  description  TEXT,
  sort_order   INTEGER     NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.opportunity_phases ENABLE ROW LEVEL SECURITY;

-- Select policy: Any authenticated user can read opportunity phases
CREATE POLICY "opportunity_phases_select_authenticated"
  ON public.opportunity_phases
  FOR SELECT
  TO authenticated
  USING (true);

-- Manage policy: Admin or the partner associated with the opportunity can manage
CREATE POLICY "opportunity_phases_admin_manage"
  ON public.opportunity_phases
  FOR ALL
  TO authenticated
  USING (
    public.is_backoffice_admin() 
    OR (opportunity_id IN (SELECT id FROM public.partner_opportunities WHERE institution_id = public.get_my_partner_id()))
  )
  WITH CHECK (
    public.is_backoffice_admin() 
    OR (opportunity_id IN (SELECT id FROM public.partner_opportunities WHERE institution_id = public.get_my_partner_id()))
  );

-- Link student_applications to opportunity_phases
ALTER TABLE public.student_applications 
  ADD COLUMN IF NOT EXISTS phase_id UUID REFERENCES public.opportunity_phases(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.student_applications.phase_id IS 'Fase específica do processo seletivo (micro-status) do parceiro';
