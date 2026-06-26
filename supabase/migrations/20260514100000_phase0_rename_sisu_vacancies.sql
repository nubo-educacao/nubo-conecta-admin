-- =============================================================================
-- Migration: Fase 0 — Padronização de Naming Convention (PRÉ-REQUISITO)
-- ADR Data-Layer Audit v2: Opção B (padronizar snake_case)
-- Sprint 8.0
-- =============================================================================

-- 0.1: Dropar a tabela fantasma (0 colunas, nunca usada) e renomear a tabela real
DROP TABLE IF EXISTS opportunities_sisu_vacancies;

ALTER TABLE opportunitiessisuvacancies RENAME TO opportunities_sisu_vacancies;

-- 0.2: Criar staging table rawsisuapprovals2026 em dev
-- Esta tabela existe em prod (271k rows) mas NÃO em dev.
CREATE TABLE IF NOT EXISTS rawsisuapprovals2026 (
    "ID candidato"              BIGINT,
    "NO_IES"                    TEXT,
    "SG_IES"                    TEXT,
    "NO_CAMPUS"                 TEXT,
    "NO_CURSO"                  TEXT,
    "DS_TURNO"                  TEXT,
    "TIPO_CONCORRENCIA"         TEXT,
    "NO_MODALIDADE_CONCORRENCIA" TEXT,
    "NU_NOTA_CANDIDATO"         TEXT,
    "NU_CLASSIFICACAO"          BIGINT
);
