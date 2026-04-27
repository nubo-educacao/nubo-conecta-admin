-- =============================================================================
-- Migration: Sprint 6 — Fix de performance da v_unified_opportunities
-- O EXPLAIN ANALYZE mostrou Seq Scan em opportunities (148K rows) e nested
-- loops sem indice nos JOINs. Adiciona indices compostos para o filtro da
-- view e atualiza estatisticas.
-- =============================================================================

-- Indice composto para o filtro WHERE do branch MEC
CREATE INDEX IF NOT EXISTS idx_opportunities_type_year_semester
  ON opportunities (opportunity_type, year, semester);

-- Indice para o JOIN opportunities → courses
CREATE INDEX IF NOT EXISTS idx_opportunities_course_id
  ON opportunities (course_id);

-- Indice para o JOIN courses → campus
CREATE INDEX IF NOT EXISTS idx_courses_campus_id
  ON courses (campus_id);

-- Indice para o JOIN campus → institutions
CREATE INDEX IF NOT EXISTS idx_campus_institution_id
  ON campus (institution_id);

-- Atualizar estatisticas das tabelas envolvidas
ANALYZE opportunities;
ANALYZE courses;
ANALYZE campus;
ANALYZE institutions;
ANALYZE important_dates;
