-- =============================================================================
-- Migration: institutions_external_code — Sprint 02 Wave 1.1
-- Adds external_code column to institutions for MEC CSV upsert join.
-- Gap 2 resolution: architect approved ADD COLUMN IF NOT EXISTS approach.
-- Circuit Breaker: review before any `supabase db push`.
-- =============================================================================

-- Adiciona external_code para vincular institutions ao código MEC
ALTER TABLE institutions ADD COLUMN IF NOT EXISTS external_code varchar;

-- Índice para performance no join do process_mec_campus_csv RPC
CREATE INDEX IF NOT EXISTS idx_institutions_external_code ON institutions(external_code);
