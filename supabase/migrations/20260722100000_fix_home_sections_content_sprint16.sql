-- Fix pontual de conteúdo: as migrations de schema da Sprint 16.0 (20260721130000/100/200)
-- já rodaram corretamente, mas 2 rows de home_sections ficaram com estado de conteúdo
-- desalinhado do plano da sprint (não é bug de schema/código, é dado):
--
-- 1. A seção match_carousel/match_results (id 2aedb50f) está com título
--    "Oportunidades em Destaque" — deveria ser "Para Você" (é o carrossel
--    personalizado por match, não o carrossel de vitrine para todos).
-- 2. A seção opportunity_carousel/featured_opportunities (id 02769e5a) — o
--    carrossel novo "Oportunidades em Destaque" (abertas primeiro, visível a
--    todos) — está com is_active=false, então nunca aparece.

UPDATE public.home_sections
  SET title = 'Para Você', updated_at = now()
  WHERE id = '2aedb50f-b6a6-453b-b303-47e9d9204e44'
    AND section_type = 'match_carousel'
    AND data_source = 'match_results';

UPDATE public.home_sections
  SET is_active = true, updated_at = now()
  WHERE id = '02769e5a-0076-4e21-978d-19dd3027a687'
    AND section_type = 'opportunity_carousel'
    AND data_source = 'featured_opportunities';
