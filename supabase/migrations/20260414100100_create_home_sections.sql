-- Sprint 5 Plano D: CMS dinâmico da Home App
CREATE TABLE public.home_sections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  section_type TEXT NOT NULL CHECK (
    section_type IN ('opportunity_carousel', 'institution_carousel', 'match_carousel', 'dates', 'hero_search', 'dynamic_cta')
  ),
  data_source TEXT NOT NULL CHECK (
    data_source IN ('partner_opportunities', 'recent_opportunities', 'match_results', 'institutions', 'important_dates', 'static')
  ),
  display_order INT DEFAULT 0,
  is_active BOOLEAN DEFAULT true,

  -- Filtros de público-alvo
  target_states TEXT[],              -- ex: {'SP', 'RJ'} — NULL = todos
  target_onboarding_status TEXT,     -- 'completed' | 'pending' | NULL = todos

  -- Config flexível
  config JSONB DEFAULT '{}'::jsonb,
  -- Exemplos de keys:
  --   "see_all_href": "/oportunidades"
  --   "limit": 8
  --   "desktop_grid_mode": true
  --   "only_authenticated": true

  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.home_sections IS 'CMS dinâmico da Home App. Cada linha = 1 seção/carrossel da Home, ordenado por display_order.';

-- Seed: replicar as seções atuais hardcoded para não quebrar nada no deploy
INSERT INTO public.home_sections (title, section_type, data_source, display_order, config) VALUES
  ('Hero Buscador', 'hero_search', 'static', 0, '{}'::jsonb),
  ('CTA Dinâmico', 'dynamic_cta', 'static', 1, '{"only_authenticated": false}'::jsonb),
  ('Para Você', 'match_carousel', 'match_results', 2, '{"only_authenticated": true}'::jsonb),
  ('Oportunidades em Destaque', 'opportunity_carousel', 'partner_opportunities', 3, '{"see_all_href": "/oportunidades", "desktop_grid_mode": true, "limit": 8}'::jsonb),
  ('Novidades', 'opportunity_carousel', 'recent_opportunities', 4, '{"see_all_href": "/oportunidades?tab=explore", "limit": 8}'::jsonb),
  ('Instituições Parceiras', 'institution_carousel', 'institutions', 5, '{"see_all_href": "/instituicoes"}'::jsonb),
  ('Datas Importantes', 'dates', 'important_dates', 6, '{}'::jsonb);

-- RLS: leitura pública (qualquer visitante vê a Home), escrita só Admin
ALTER TABLE public.home_sections ENABLE ROW LEVEL SECURITY;

CREATE POLICY "home_sections_read_all"
  ON public.home_sections
  FOR SELECT
  USING (true);

-- Admin escrita: usa supabase_service (service role), não precisa de policy para INSERT/UPDATE/DELETE
