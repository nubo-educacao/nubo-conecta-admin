-- Sprint 16.0: ADR-0023 — Novos data_sources dedicados no CMS da Home

-- 1. Dropar constraint antigo e recriar com novos valores
ALTER TABLE public.home_sections DROP CONSTRAINT IF EXISTS home_sections_data_source_check;
ALTER TABLE public.home_sections ADD CONSTRAINT home_sections_data_source_check CHECK (
  data_source IN (
    'partner_opportunities', 'recent_opportunities', 'match_results',
    'institutions', 'important_dates', 'static',
    'featured_opportunities', 'institutions_with_open_opps'
  )
);

-- 2. Migrar seções existentes para os novos data_sources
UPDATE public.home_sections
  SET data_source = 'featured_opportunities', updated_at = now()
  WHERE data_source = 'partner_opportunities'
    AND section_type = 'opportunity_carousel';

-- 'Instituições Parceiras' -> 'Instituições em Destaque' (carrossel passa a ser
-- unificado: parceiras + MEC, priorizadas por vagas abertas — ver 1.2/2.4)
UPDATE public.home_sections
  SET data_source = 'institutions_with_open_opps',
      title = 'Instituições em Destaque',
      updated_at = now()
  WHERE data_source = 'institutions'
    AND section_type = 'institution_carousel';
