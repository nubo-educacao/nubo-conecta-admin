-- =============================================================================
-- Migration: partner_opportunities — Sprint 02 Wave 1.3
-- Tabela de oportunidades parceiras com lifecycle de aprovação editorial.
-- RLS: SELECT apenas aprovadas (público), ALL para admin autenticado.
-- Nota: VARCHAR em vez de ENUM para flexibilidade de migração futura (add values sem ALTER TYPE).
-- =============================================================================

CREATE TABLE IF NOT EXISTS partner_opportunities (
  id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  institution_id           UUID        NOT NULL REFERENCES institutions(id) ON DELETE RESTRICT,
  name                     TEXT        NOT NULL,
  description              TEXT,
  opportunity_type         VARCHAR     NOT NULL CHECK (opportunity_type IN ('bolsa', 'bootcamp', 'mentoria')),
  eligibility_criteria     JSONB       NOT NULL DEFAULT '{}',
  external_redirect_config JSONB       NOT NULL DEFAULT '{}',  -- { "enabled": bool, "url": string }
  status                   VARCHAR     NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending_review', 'approved')),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE partner_opportunities ENABLE ROW LEVEL SECURITY;

-- Leitura pública: apenas oportunidades com status 'approved' são visíveis ao catálogo
CREATE POLICY "partner_opp_select_approved"
  ON partner_opportunities
  FOR SELECT
  USING (status = 'approved');

-- Escrita: admin autenticado pode gerenciar todas as oportunidades (inclusive draft/pending_review)
-- Usa is_backoffice_admin() SECURITY DEFINER — padrão do schema real (migration 77).
CREATE POLICY "partner_opp_admin_manage"
  ON partner_opportunities
  FOR ALL
  TO authenticated
  USING (public.is_backoffice_admin())
  WITH CHECK (public.is_backoffice_admin());
