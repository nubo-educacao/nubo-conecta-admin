-- =============================================================================
-- Migration: allow_admin_manage_institutions
-- Permite que administradores do backoffice e usuários com permissão 'Parceiros'
-- possam inserir, atualizar e gerenciar registros nas tabelas institutions,
-- partner_institutions e partner_opportunities.
-- Corrige violação de RLS (42501) no cadastro/edição de parceiros.
-- =============================================================================

-- 1. institutions: política de gerenciamento para admin e permissão 'Parceiros'
DROP POLICY IF EXISTS "institutions_admin_manage" ON public.institutions;
CREATE POLICY "institutions_admin_manage"
  ON public.institutions
  FOR ALL
  TO authenticated
  USING (
    public.is_backoffice_admin()
    OR EXISTS (
      SELECT 1 FROM public.user_permissions
      WHERE user_id = auth.uid() AND permission = 'Parceiros'
    )
  )
  WITH CHECK (
    public.is_backoffice_admin()
    OR EXISTS (
      SELECT 1 FROM public.user_permissions
      WHERE user_id = auth.uid() AND permission = 'Parceiros'
    )
  );

-- 2. partner_institutions: atualiza para aceitar também permissão 'Parceiros'
DROP POLICY IF EXISTS "partner_institutions_admin_manage" ON public.partner_institutions;
CREATE POLICY "partner_institutions_admin_manage"
  ON public.partner_institutions
  FOR ALL
  TO authenticated
  USING (
    public.is_backoffice_admin()
    OR EXISTS (
      SELECT 1 FROM public.user_permissions
      WHERE user_id = auth.uid() AND permission = 'Parceiros'
    )
  )
  WITH CHECK (
    public.is_backoffice_admin()
    OR EXISTS (
      SELECT 1 FROM public.user_permissions
      WHERE user_id = auth.uid() AND permission = 'Parceiros'
    )
  );

-- 3. partner_opportunities: atualiza para aceitar também permissão 'Parceiros'
DROP POLICY IF EXISTS "partner_opp_admin_manage" ON public.partner_opportunities;
CREATE POLICY "partner_opp_admin_manage"
  ON public.partner_opportunities
  FOR ALL
  TO authenticated
  USING (
    public.is_backoffice_admin()
    OR EXISTS (
      SELECT 1 FROM public.user_permissions
      WHERE user_id = auth.uid() AND permission = 'Parceiros'
    )
  )
  WITH CHECK (
    public.is_backoffice_admin()
    OR EXISTS (
      SELECT 1 FROM public.user_permissions
      WHERE user_id = auth.uid() AND permission = 'Parceiros'
    )
  );
