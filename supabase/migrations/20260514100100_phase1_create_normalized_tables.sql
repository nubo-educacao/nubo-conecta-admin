-- =============================================================================
-- Migration: Fase 1 — Tabelas Normalizadas de Vagas e Aprovados
-- Sprint 8.0
-- =============================================================================

-- 1.1: Criar opportunities_prouni_vacancies
-- Consolida bolsas ofertadas E ocupadas (ProUni vacancies + occupied) numa única tabela.
CREATE TABLE IF NOT EXISTS opportunities_prouni_vacancies (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  opportunity_id          UUID NOT NULL REFERENCES opportunities(id),
  ds_tipo_bolsa           TEXT NOT NULL,         -- 'BOLSA INTEGRAL' | 'BOLSA PARCIAL 50%'
  bolsas_ampla_ofertada   INTEGER DEFAULT 0,
  bolsas_cota_ofertada    INTEGER DEFAULT 0,
  bolsas_ampla_ocupada    INTEGER DEFAULT 0,
  bolsas_cota_ocupada     INTEGER DEFAULT 0,
  year                    INTEGER NOT NULL,
  semester                TEXT NOT NULL DEFAULT '1',
  created_at              TIMESTAMPTZ DEFAULT now(),
  updated_at              TIMESTAMPTZ DEFAULT now(),
  UNIQUE(opportunity_id, ds_tipo_bolsa)
);

ALTER TABLE opportunities_prouni_vacancies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "prouni_vacancies_public_read" ON opportunities_prouni_vacancies
  FOR SELECT USING (true);

CREATE POLICY "prouni_vacancies_service_write" ON opportunities_prouni_vacancies
  FOR ALL USING (auth.role() = 'service_role');

-- 1.2: Criar opportunities_sisu_approvals
-- Armazena agregados por cota (não rows individuais de 271k candidatos).
-- Cada row = 1 opportunity + 1 tipo de concorrência.
CREATE TABLE IF NOT EXISTS opportunities_sisu_approvals (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  opportunity_id          UUID NOT NULL REFERENCES opportunities(id),
  tipo_concorrencia       TEXT NOT NULL,         -- 'AC', 'LB_PPI', 'LB_EP', etc.
  modalidade_concorrencia TEXT,                  -- Descrição completa da modalidade
  qt_aprovados            INTEGER DEFAULT 0,     -- Quantidade de aprovados nesta cota
  nota_minima             NUMERIC,               -- Menor nota entre aprovados
  nota_maxima             NUMERIC,               -- Maior nota entre aprovados
  nota_media              NUMERIC,               -- Média das notas dos aprovados
  year                    INTEGER NOT NULL,
  created_at              TIMESTAMPTZ DEFAULT now(),
  updated_at              TIMESTAMPTZ DEFAULT now(),
  UNIQUE(opportunity_id, tipo_concorrencia, year)
);

ALTER TABLE opportunities_sisu_approvals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sisu_approvals_public_read" ON opportunities_sisu_approvals
  FOR SELECT USING (true);

CREATE POLICY "sisu_approvals_service_write" ON opportunities_sisu_approvals
  FOR ALL USING (auth.role() = 'service_role');
