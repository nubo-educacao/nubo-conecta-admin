-- =============================================================================
-- Migration: add_is_partner_to_institutions — Sprint 02 Wave 4.2
-- Adiciona a flag is_partner à tabela de instituições para permitir
-- filtragem eficiente no catálogo de parceiras.
-- =============================================================================

ALTER TABLE institutions 
ADD COLUMN IF NOT EXISTS is_partner BOOLEAN DEFAULT false;

-- 1. Index para otimizar o filtro do catálogo de parceiras
CREATE INDEX IF NOT EXISTS idx_institutions_is_partner 
ON institutions(is_partner) 
WHERE is_partner = true;

-- 2. Atualizar estatísticas
ANALYZE institutions;
