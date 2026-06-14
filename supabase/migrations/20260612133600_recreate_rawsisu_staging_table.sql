-- 20260612133600_recreate_rawsisu_staging_table.sql
-- Recreates the rawsisu staging table that was accidentally dropped.
-- Column list derived from the actual 2026 CSV header (0_rawsisu2026.csv).
-- All columns are text to support dot-formatted numbers and avoid import type errors.

CREATE TABLE IF NOT EXISTS public.rawsisu (
  "EDICAO"                    text,
  "CO_IES"                    text,
  "NO_IES"                    text,
  "SG_IES"                    text,
  "DS_ORGANIZACAO_ACADEMICA"  text,
  "DS_CATEGORIA_ADM"          text,
  "NO_CAMPUS"                 text,
  "NO_MUNICIPIO_CAMPUS"       text,
  "SG_UF_CAMPUS"              text,
  "DS_REGIAO_CAMPUS"          text,
  "CO_IES_CURSO"              text,
  "NO_CURSO"                  text,
  "DS_GRAU"                   text,
  "DS_TURNO"                  text,
  "TP_MOD_CONCORRENCIA"       text,
  "TIPO_CONCORRENCIA"         text,
  "DS_MOD_CONCORRENCIA"       text,
  "NU_PERCENTUAL_BONUS"       text,
  "QT_VAGAS_CONCORRENCIA"     text,
  "NU_NOTACORTE"              text,
  "QT_INSCRICAO"              text
);

-- Enable Row Level Security
ALTER TABLE public.rawsisu ENABLE ROW LEVEL SECURITY;

-- Allow service role full access
CREATE POLICY "rawsisu_service_all" ON public.rawsisu
  FOR ALL USING (true);
