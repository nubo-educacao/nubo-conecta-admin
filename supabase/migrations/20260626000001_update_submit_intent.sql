-- Update system_intent for submit to require knowledge base consultation
UPDATE system_intents
SET trigger_message = 'O usuário finalizou a candidatura a uma oportunidade! Dê os parabéns pela candidatura de forma calorosa e entusiasmada. MUITO IMPORTANTE: Antes de responder sobre os próximos passos, OBRIGATORIAMENTE use a ferramenta query_educational_catalog para buscar na tabela knowledge_documents pelo documento desta oportunidade ou parceiro, e a ferramenta download_knowledge_document para baixar o conteúdo do documento usando o storage_path retornado. Baseie sua resposta sobre os próximos passos ESTRITAMENTE na documentação do parceiro e ofereça ajuda para explorar outras oportunidades.'
WHERE command = 'submit';
