-- =============================================================================
-- Migration: partner_opportunities — Sprint 11.0 Card 9.3.1
-- Substituir CHECK constraint de status: (draft, pending_review, approved)
-- → (inactive, incoming, opened, closed)
-- Backfill: approved → opened, draft/pending_review → inactive
-- RLS: atualizar policy de SELECT para os novos status visíveis.
-- =============================================================================

-- 1. Remover constraint antiga temporariamente
ALTER TABLE public.partner_opportunities
  DROP CONSTRAINT IF EXISTS partner_opportunities_status_check;

-- 2. Backfill existentes
UPDATE public.partner_opportunities SET status = 'opened' WHERE status = 'approved';
UPDATE public.partner_opportunities SET status = 'inactive' WHERE status IN ('draft', 'pending_review');

-- 3. Adicionar nova constraint
ALTER TABLE public.partner_opportunities
  ADD CONSTRAINT partner_opportunities_status_check
    CHECK (status IN ('inactive', 'incoming', 'opened', 'closed'));

-- 3. Novo default
ALTER TABLE public.partner_opportunities
  ALTER COLUMN status SET DEFAULT 'inactive';

-- 4. Atualizar RLS policy de SELECT: expor incoming, opened e closed (não inactive)
DROP POLICY IF EXISTS "partner_opp_select_approved" ON public.partner_opportunities;

CREATE POLICY "partner_opp_select_visible"
  ON public.partner_opportunities
  FOR SELECT
  USING (status IN ('incoming', 'opened', 'closed') OR public.is_backoffice_admin());
