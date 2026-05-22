-- Migration: Sprint 13.0 — Documento de Autoconhecimento da Cloudinha
-- Criado em: 2026-05-22
-- Card: 3b912c74 (Conteúdo de Autoconhecimento)
--
-- PASSO 1: Inserir documento em knowledge_documents
-- Nota: storage_path aponta para o arquivo que deve ser uploadado em:
--   Bucket: knowledge-base
--   Path: documents/autoconhecimento_nubo_cloudinha.md
--   Arquivo local: cloudinha-conecta-agent/content/autoconhecimento_nubo_cloudinha.md

INSERT INTO knowledge_documents (title, description, category_id, storage_path, is_active, current_version)
VALUES (
  'Sobre o Nubo Conecta e a Cloudinha',
  'Documento de autoconhecimento da Cloudinha: o que é o Nubo Conecta, quem é a Cloudinha, o que pode e não pode fazer, como funcionam candidaturas e ferramentas disponíveis.',
  'fb92e8e3-4fd1-49e1-9b15-9573d2064bfc', -- category: cloudinha
  'documents/autoconhecimento_nubo_cloudinha.md',
  true,
  1
)
RETURNING id;

-- PASSO 2: Inserir keywords (substituir <DOCUMENT_ID> pelo UUID retornado acima)
-- Execute após obter o ID do INSERT acima:
--
-- INSERT INTO knowledge_keywords (document_id, keyword) VALUES
--   ('<DOCUMENT_ID>', 'nubo conecta'),
--   ('<DOCUMENT_ID>', 'cloudinha'),
--   ('<DOCUMENT_ID>', 'o que é'),
--   ('<DOCUMENT_ID>', 'como funciona'),
--   ('<DOCUMENT_ID>', 'candidatura'),
--   ('<DOCUMENT_ID>', 'o que você pode fazer'),
--   ('<DOCUMENT_ID>', 'assistente'),
--   ('<DOCUMENT_ID>', 'plataforma educacional');

-- PASSO 3: Atualizar trigger_message do system_intent page_context
-- Remove placeholders {{title}}/{{institution}} que não existem na view
-- e delega o lookup de dados ao agente ReAct via opportunity_id

UPDATE system_intents
SET trigger_message = 'O usuário acabou de abrir a página de detalhes de uma oportunidade educacional (unified_id: {{opportunity_id}}). Consulte o catálogo educacional usando query_educational_catalog para buscar os detalhes dessa oportunidade pelo unified_id e dê um resumo acolhedor: nome do curso, instituição, tipo (Sisu/ProUni/Parceiro) e qualquer informação relevante. Se for uma oportunidade de parceiro, busque também na base de conhecimento por documentos relacionados ao programa do parceiro. Seja breve e convidativa.'
WHERE id = '973d42d4-6120-4751-9185-3afb853afcc5';
