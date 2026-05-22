-- Create programs table for managing MEC programs (SiSU, ProUni)
CREATE TABLE public.programs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type TEXT NOT NULL CHECK (type IN ('sisu', 'prouni')),
  cycle_year INTEGER NOT NULL,
  cycle_semester TEXT NOT NULL CHECK (cycle_semester IN ('1', '2')),
  title TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'incoming' CHECK (status IN ('incoming', 'opened', 'closed')),
  redirect_url TEXT,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(type, cycle_year, cycle_semester)
);

-- Enable RLS
ALTER TABLE public.programs ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "programs_select_all" ON public.programs
  FOR SELECT USING (true);

CREATE POLICY "programs_admin_all" ON public.programs
  FOR ALL USING (public.is_backoffice_admin());

-- Initial seeds
INSERT INTO public.programs (type, cycle_year, cycle_semester, title, description, status, redirect_url) VALUES
('sisu', 2026, '1', 'SiSU 2026.1', 'O SiSU (Sistema de Seleção Unificada) utiliza a nota do ENEM para classificar candidatos em vagas de instituições públicas. A concorrência é baseada na nota de corte, que varia diariamente durante o período de inscrição.', 'opened', 'https://sisu.mec.gov.br'),
('prouni', 2025, '1', 'ProUni 2025.1', 'O ProUni concede bolsas de estudo integrais e parciais em instituições privadas de ensino superior a estudantes de cursos de graduação e sequenciais de formação específica.', 'closed', 'https://prouniportal.mec.gov.br');
