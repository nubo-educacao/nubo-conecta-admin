-- =============================================================================
-- Migration: Sprint 6 — Tabela admin_alerts para Action Center
-- Alertas operacionais gerados automaticamente (deadlines, periodos MEC, etc.)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.admin_alerts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_type      text NOT NULL,
    severity        text NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    title           text NOT NULL,
    description     text,
    entity_type     text,
    entity_id       text,
    action_label    text,
    action_type     text,
    action_metadata jsonb DEFAULT '{}'::jsonb,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'acknowledged', 'resolved', 'dismissed')),
    resolved_by     uuid REFERENCES auth.users(id),
    resolved_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz
);

COMMENT ON TABLE public.admin_alerts IS 'Alertas operacionais do Action Center — gerados por Edge Functions de checagem de deadlines';

-- Indices para queries do Action Center
CREATE INDEX IF NOT EXISTS idx_admin_alerts_pending
  ON public.admin_alerts (created_at DESC)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_admin_alerts_type_created
  ON public.admin_alerts (alert_type, created_at DESC);

-- RLS: apenas admins do backoffice
ALTER TABLE public.admin_alerts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_alerts_select_backoffice"
  ON public.admin_alerts FOR SELECT
  TO authenticated
  USING (public.is_backoffice_admin());

CREATE POLICY "admin_alerts_insert_backoffice"
  ON public.admin_alerts FOR INSERT
  TO authenticated
  WITH CHECK (public.is_backoffice_admin());

CREATE POLICY "admin_alerts_update_backoffice"
  ON public.admin_alerts FOR UPDATE
  TO authenticated
  USING (public.is_backoffice_admin())
  WITH CHECK (public.is_backoffice_admin());
