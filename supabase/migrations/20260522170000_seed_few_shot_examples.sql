-- Seed: Few-Shot Examples iniciais
-- Sprint 13.0 — Card: Backoffice: Criação e Configuração de Few-Shot Examples
-- Nota: starter_id referencia cloudinha_starters; usamos NULL quando starter não é conhecido
-- para garantir que este seed seja idempotente em qualquer ambiente.

INSERT INTO few_shot_examples
  (category, starter_id, user_message, expected_tools, expected_response, is_active, sort_order)
VALUES
  (
    'geral',
    NULL,
    'Oi, tudo bem?',
    '[]'::jsonb,
    'Oi! Tudo ótimo por aqui. Sou a Cloudinha, sua assistente educacional do Nubo Conecta. Posso te ajudar a encontrar bolsas, cursos e oportunidades. O que você gostaria de saber?',
    true, 0
  ),
  (
    'geral',
    NULL,
    'O que é o Nubo Conecta?',
    '["query_educational_catalog","download_knowledge_document"]'::jsonb,
    'O Nubo Conecta é uma plataforma que conecta estudantes a oportunidades de educação superior, como bolsas ProUni, vagas Sisu e programas de parceiros. Posso te mostrar as oportunidades disponíveis para o seu perfil!',
    true, 1
  ),
  (
    'prouni',
    NULL,
    'Quais bolsas do ProUni estão abertas?',
    '["query_educational_catalog","download_knowledge_document"]'::jsonb,
    'Vou verificar as bolsas do ProUni abertas no momento. [Usa query_educational_catalog para buscar oportunidades do tipo ProUni com status ativo, depois resume as principais com nome do curso, instituição e nota de corte].',
    true, 2
  ),
  (
    'sisu',
    NULL,
    'Qual a nota de corte para Medicina na USP?',
    '["query_educational_catalog"]'::jsonb,
    'Para verificar a nota de corte de Medicina na USP pelo Sisu, vou consultar o catálogo atualizado. [Usa query_educational_catalog filtrando por nome de curso "Medicina", instituição "USP" e tipo "sisu", retornando nota_corte_minima].',
    true, 3
  ),
  (
    'match',
    NULL,
    'Quais oportunidades combinam comigo?',
    '["get_student_context","query_educational_catalog"]'::jsonb,
    'Vou analisar o seu perfil e as oportunidades disponíveis para encontrar as melhores opções para você. [Usa get_student_context para buscar perfil, nota ENEM e preferências, depois query_educational_catalog para retornar as oportunidades com maior match_score].',
    true, 4
  ),
  (
    'candidatura',
    NULL,
    'Como está minha candidatura?',
    '["get_student_context"]'::jsonb,
    'Vou verificar o status das suas candidaturas agora. [Usa get_student_context para buscar student_applications do perfil ativo, retornando status e nome das oportunidades candidatadas].',
    true, 5
  ),
  (
    'parceiro',
    NULL,
    'O que é o programa do Instituto XYZ?',
    '["query_educational_catalog","download_knowledge_document"]'::jsonb,
    'Vou buscar as informações sobre o programa do Instituto XYZ. [Usa query_educational_catalog para localizar a instituição parceira e o documento de edital associado, depois download_knowledge_document para ler o conteúdo completo].',
    true, 6
  ),
  (
    'perfil',
    NULL,
    'Quero atualizar meu perfil',
    '["get_student_context"]'::jsonb,
    'Posso te ajudar! Para atualizar seus dados, acesse a seção "Meu Perfil" no menu. Se quiser, posso revisar as informações que temos sobre você agora.',
    true, 7
  );
