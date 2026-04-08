-- =============================================================================
-- Migration: optimize_unified_view — Sprint 02 Wave 6
-- Adiciona índices de performance para acelerar o sorting da view v_unified_opportunities.
-- Foco: 'is_partner' (ordenação base) e 'created_at' (recência).
-- =============================================================================

-- 1. Índice para ordenação por recência nas oportunidades MEC
-- Otimiza a ordenação da branch SELECT da branch superior da UNION ALL.
CREATE INDEX IF NOT EXISTS idx_opportunities_created_at_desc 
ON opportunities(created_at DESC);

-- 2. Índice para ordenação por recência nas oportunidades Parceiras
-- Otimiza a ordenação da branch SELECT inferior da UNION ALL.
CREATE INDEX IF NOT EXISTS idx_partner_opportunities_created_at_desc 
ON partner_opportunities(created_at DESC);

-- 3. Índice para o filtro de status 'approved' usado na view
-- Garante que a branch de parceiros filtre rápido o dataset de busca.
CREATE INDEX IF NOT EXISTS idx_partner_opportunities_status_approved 
ON partner_opportunities(status) 
WHERE status = 'approved';

-- 4. Rodar ANALYZE para atualizar as estatísticas do planner
-- Crucial para que o Postgres use os novos índices imediatamente.
ANALYZE opportunities;
ANALYZE partner_opportunities;
ANALYZE courses;
ANALYZE campus;
ANALYZE institutions;
