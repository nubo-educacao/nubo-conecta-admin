-- Sprint 3.8: Add location column to partner_institutions
-- Required for InstitutionCarousel and /instituicoes page subtitle.
ALTER TABLE public.partner_institutions
  ADD COLUMN IF NOT EXISTS location TEXT;

COMMENT ON COLUMN public.partner_institutions.location IS 'Display location for the partner (e.g. "Nacional", "São Paulo")';
