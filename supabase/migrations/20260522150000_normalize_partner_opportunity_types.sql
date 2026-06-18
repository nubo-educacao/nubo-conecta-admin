-- Sprint 13.0 — Consistência Universal de Tipos
-- Substitui constraint antiga (bolsa, financiamento, vaga_estagio, vaga_emprego, programa de bolsa)
-- pelos dois tipos canônicos: 'programa de bolsa' e 'programa educacional'.
-- Todos os registros existentes já são 'programa de bolsa', sem data migration necessária.

ALTER TABLE partner_opportunities
  DROP CONSTRAINT IF EXISTS partner_opportunities_opportunity_type_check;

-- Migrar valores antigos para os novos tipos canônicos
UPDATE partner_opportunities
SET opportunity_type = 'programa de bolsa'
WHERE opportunity_type NOT IN ('programa de bolsa', 'programa educacional');

ALTER TABLE partner_opportunities
  ADD CONSTRAINT partner_opportunities_opportunity_type_check
  CHECK (opportunity_type IN ('programa de bolsa', 'programa educacional'));
