-- Alter rawsisu staging table to support both 2025 and 2026 formats
-- 20260609210451_add_qt_vagas_concorrencia_to_rawsisu.sql

ALTER TABLE public.rawsisu 
  ADD COLUMN IF NOT EXISTS "QT_VAGAS_CONCORRENCIA" text;
