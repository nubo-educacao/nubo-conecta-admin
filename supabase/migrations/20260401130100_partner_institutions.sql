-- =============================================================================
-- Migration: partner_institutions — Sprint 02 Wave 1.2
-- Tabela de branding 1:1 para instituições parceiras privadas.
-- RLS: SELECT público (catálogo), INSERT/UPDATE/DELETE restrito a admin autenticado.
-- =============================================================================

CREATE TABLE IF NOT EXISTS partner_institutions (
  institution_id  UUID PRIMARY KEY REFERENCES institutions(id) ON DELETE CASCADE,
  logo_url        TEXT,
  cover_url       TEXT,
  description     TEXT,
  brand_color     TEXT
);

ALTER TABLE partner_institutions ENABLE ROW LEVEL SECURITY;

-- Leitura pública: anon e authenticated podem visualizar branding das parceiras
CREATE POLICY "partner_institutions_select_all"
  ON partner_institutions
  FOR SELECT
  USING (true);

-- Escrita: apenas admin autenticado pode gerenciar (usa is_backoffice_admin() — migration 77)
CREATE POLICY "partner_institutions_admin_manage"
  ON partner_institutions
  FOR ALL
  TO authenticated
  USING (public.is_backoffice_admin())
  WITH CHECK (public.is_backoffice_admin());
