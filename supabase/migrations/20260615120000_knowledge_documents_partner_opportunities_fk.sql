-- Sprint 13.0 — Migrar knowledge_documents.partner_id de partners → partner_opportunities

-- 1. Nullificar documentos de parceiros legados sem partner_opportunity correspondente
--    (Fundação Behring, Insper Integral, Insper Parcial não têm institution_id para criar partner_opportunity)
UPDATE knowledge_documents
SET partner_id = NULL
WHERE partner_id IN (
  'cd6be5e6-0131-40d5-8644-e949b2f244af', -- Fundação Behring
  '4a0810db-c457-467b-b85b-a007737bfbd3', -- Bolsa Integral do Insper
  'e7ec6b25-8e63-456f-beb7-155c02886cdc'  -- Bolsa Parcial do Insper
);

-- 2. Remover FK antiga e coluna partner_id
ALTER TABLE knowledge_documents
  DROP CONSTRAINT IF EXISTS knowledge_documents_partner_id_fkey;

ALTER TABLE knowledge_documents
  DROP COLUMN IF EXISTS partner_id;

-- 3. Adicionar nova coluna partner_id → partner_opportunities
ALTER TABLE knowledge_documents
  ADD COLUMN partner_id UUID REFERENCES partner_opportunities(id) ON DELETE SET NULL;
