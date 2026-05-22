-- =============================================================================
-- Migration: partner_forms — Sprint 11.0 Card 9.3.2a T1
-- Adicionar coluna criterion_type para distinguir entre critérios de
-- elegibilidade (eliminatório) e priorização (preferencial).
-- =============================================================================

ALTER TABLE public.partner_forms
  ADD COLUMN IF NOT EXISTS criterion_type TEXT DEFAULT 'eligibility'
    CHECK (criterion_type IN ('eligibility', 'priority'));

-- Backfill: campos existentes com is_criterion = true são elegibilidade
UPDATE public.partner_forms
SET criterion_type = 'eligibility'
WHERE is_criterion = true AND criterion_type IS NULL;
