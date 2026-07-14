-- 20260710120000_add_explain_match_intent_and_examples.sql
-- Sprint 14.0: Cloudinha - Lógica de Vagas Ociosas e Explain Match
-- Cadastra o system_intent 'explain_match' (botão "Entender Match pela Cloudinha" em
-- DetailsLayout.tsx) e os learning_examples de vagas ociosas ProUni + explain_match,
-- conforme Tactical Plan 567973be-e99d-4147-98be-ca99c2ea50e1 (revisado no Peer Review).

-- system_intents: explain_match
-- trigger_route restringe a rotas de detalhe de oportunidade (mesmo padrão do seed de page_context).
-- trigger_type = 'manual' pois é disparado por clique no botão, não por mudança de rota.
-- open_drawer = true para abrir o drawer automaticamente com a explicação.
INSERT INTO public.system_intents (command, trigger_route, trigger_type, open_drawer, delay_ms, trigger_message, description, is_active)
VALUES (
    'explain_match',
    '^/oportunidades/.+$',
    'manual',
    true,
    0,
    'O usuário clicou em "Entender Match pela Cloudinha" na oportunidade {{opportunity_id}}. Explique de forma detalhada e acolhedora por que essa oportunidade tem esse nível de compatibilidade com o perfil dele. OBRIGATORIAMENTE use a ferramenta get_student_context para consultar user_opportunity_matches (colunas match_score, match_details) filtrando por profile_id e unified_opportunity_id = ''{{opportunity_id}}''. Baseie a explicação nos fatores presentes em match_details (ex: pesos do ENEM, nota de corte, localização, renda, cotas) de forma clara e sem jargão técnico.',
    'Explica o Match Score de uma oportunidade específica quando o usuário clica no botão "Entender Match pela Cloudinha".',
    true
);

-- learning_examples: Exemplo 1 — roteamento de vagas ociosas ProUni
-- Nomes de coluna corrigidos no Peer Review: qt_vagas_ofertadas_current/_prev (não existe
-- coluna sem sufixo), com o mesmo padrão de coalesce já usado em vagas_ociosas_current/_prev.
-- Correção adicional (achada em teste manual pós-execução):
--   1) vagas_ociosas_current/_prev são BOOLEAN, não numéricas — comparar com `= true`, nunca `> 0`
--      (o antigo `> 0` gera "operator does not exist: boolean > integer").
--   2) status válido é 'opened' (ADR-0013), não 'approved' — o system_instruction ativo em
--      agent_prompts ainda referencia 'approved', que hoje não retorna nenhuma linha na view.
INSERT INTO public.learning_examples (id, intent_category, input_query, ideal_output, reasoning, is_active, source)
VALUES (
    gen_random_uuid(),
    'prouni',
    'Quais vagas do ProUni tem disponíveis com vagas ociosas?',
    'Vou buscar as vagas do ProUni com vagas ociosas disponíveis agora mesmo!

<call tool="query_educational_catalog" target="v_unified_opportunities">
SELECT title, provider_name, location,
       COALESCE(vagas_ociosas_current, vagas_ociosas_prev) AS vagas_ociosas,
       COALESCE(qt_vagas_ofertadas_current, qt_vagas_ofertadas_prev) AS vagas_ofertadas
FROM v_unified_opportunities
WHERE type = ''prouni''
  AND status = ''opened''
  AND COALESCE(vagas_ociosas_current, vagas_ociosas_prev) = true
ORDER BY vagas_ociosas DESC
LIMIT 10;
</call>',
    'vagas_ociosas_current/_prev são BOOLEAN — usar "= true", nunca "> 0". status válido é ''opened'' (ADR-0013), não ''approved''. Sempre fazer COALESCE(current, prev), nunca referenciar as colunas sem sufixo, pois não existem.',
    true,
    'seed'
),
(
    gen_random_uuid(),
    'explain_match',
    '[[system_intent: explain_match]]',
    'Vou analisar seu perfil para entender a compatibilidade com essa oportunidade!

<call tool="get_student_context" target="user_opportunity_matches">
SELECT match_score, match_details
FROM user_opportunity_matches
WHERE profile_id = :profile_id AND unified_opportunity_id = :opportunity_id
LIMIT 1;
</call>

Com base nos dados retornados, explico os fatores de compatibilidade (pesos do ENEM, nota de corte, localização, renda, cotas) de forma acolhedora, citando o percentual de match encontrado em match_score.',
    'match_score e match_details só existem em user_opportunity_matches, não na view pública — sempre usar get_student_context (nunca query_educational_catalog) para este intent.',
    true,
    'seed'
);
