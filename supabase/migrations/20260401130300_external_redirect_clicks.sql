-- =============================================================================
-- Migration: external_redirect_clicks — Sprint 02 Wave 1.4
-- Tabela de rastreamento obrigatório de redirects externos.
-- HARD REQUIREMENT: o Server Action trackAndRedirect insere ANTES de retornar a URL.
-- RLS: authenticated pode inserir os próprios clicks; admin pode SELECT ALL.
-- =============================================================================

CREATE TABLE IF NOT EXISTS external_redirect_clicks (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  partner_id   UUID        REFERENCES institutions(id) ON DELETE SET NULL,
  redirect_url TEXT        NOT NULL,
  source       TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE external_redirect_clicks ENABLE ROW LEVEL SECURITY;

-- Usuário autenticado pode inserir apenas seus próprios clicks
CREATE POLICY "redirect_clicks_insert_own"
  ON external_redirect_clicks
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Admin pode ler todos os clicks para analytics (usa is_backoffice_admin() — migration 77)
CREATE POLICY "redirect_clicks_admin_read"
  ON external_redirect_clicks
  FOR SELECT
  TO authenticated
  USING (public.is_backoffice_admin());
