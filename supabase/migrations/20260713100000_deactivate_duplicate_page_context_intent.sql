-- 20260713100000_deactivate_duplicate_page_context_intent.sql
-- Bug achado em teste manual: existiam 2 rows ativas para command='page_context' com a
-- mesma trigger_route ('^/oportunidades/.+$'). resolveIntentFromDB (system-intents.ts) não
-- usa ORDER BY, então o Postgres retorna as duas em ordem não-garantida e o .find() pega
-- uma ou outra de forma inconsistente entre requests.
--
-- Row e2e38ca1 (criada em 2026-06-14) usa placeholders {{title}}/{{institution}} que o
-- frontend NUNCA preenche — useSystemIntents.ts só envia page_data: { opportunity_id }.
-- Resultado: mensagem literal "explorando a oportunidade de {{title}} na {{institution}}".
--
-- Row 973d42d4 (criada em 2026-04-14) é autossuficiente: usa {{opportunity_id}} e instrui
-- o agente a buscar os dados via query_educational_catalog. Essa é a correta — mantém ativa.
UPDATE public.system_intents
SET is_active = false
WHERE id = 'e2e38ca1-29f1-4269-83ed-40529db6bcb4';
