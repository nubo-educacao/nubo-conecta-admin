-- Migration: Padronizar a relação de knowledge_documents com partner_opportunities
-- Data: 2026-06-18
-- Contexto: a relação de "Parceiro" do documento estava inconsistente:
--   - FK dev → partners | FK prod → partner_opportunities
--   - RPC get_knowledge_documents fazia LEFT JOIN partners (partner_name vinha NULL)
--   - Dropdown do admin lia de `partners` (BIP Impulsiona não aparecia, pois só existe
--     em partner_opportunities)
-- Decisão: padronizar TUDO em partner_opportunities.

-- ---------------------------------------------------------------------------
-- 1) FK partner_id → partner_opportunities (idempotente; prod já estava assim)
-- ---------------------------------------------------------------------------
ALTER TABLE public.knowledge_documents
  DROP CONSTRAINT IF EXISTS knowledge_documents_partner_id_fkey;

ALTER TABLE public.knowledge_documents
  ADD CONSTRAINT knowledge_documents_partner_id_fkey
  FOREIGN KEY (partner_id) REFERENCES public.partner_opportunities(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- 2) RPC get_knowledge_documents: LEFT JOIN partner_opportunities (não partners)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_knowledge_documents(
    p_category_id uuid DEFAULT NULL::uuid,
    p_partner_id uuid DEFAULT NULL::uuid,
    p_is_active boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_results JSONB;
BEGIN
    SELECT jsonb_agg(row_data ORDER BY row_data->>'updated_at' DESC) INTO v_results
    FROM (
        SELECT jsonb_build_object(
            'id', kd.id,
            'title', kd.title,
            'description', kd.description,
            'category_id', kd.category_id,
            'category_name', kc.name,
            'category_label', kc.label,
            'partner_id', kd.partner_id,
            'partner_name', p.name,
            'storage_path', kd.storage_path,
            'is_active', kd.is_active,
            'current_version', kd.current_version,
            'created_by', kd.created_by,
            'created_at', kd.created_at,
            'updated_at', kd.updated_at,
            'keywords', COALESCE((
                SELECT jsonb_agg(kk.keyword)
                FROM public.knowledge_keywords kk
                WHERE kk.document_id = kd.id
            ), '[]'::jsonb)
        ) AS row_data
        FROM public.knowledge_documents kd
        LEFT JOIN public.knowledge_categories kc ON kd.category_id = kc.id
        LEFT JOIN public.partner_opportunities p ON kd.partner_id = p.id
        WHERE (p_category_id IS NULL OR kd.category_id = p_category_id)
          AND (p_partner_id IS NULL OR kd.partner_id = p_partner_id)
          AND (p_is_active IS NULL OR kd.is_active = p_is_active)
    ) sub;

    RETURN COALESCE(v_results, '[]'::jsonb);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2.5) Criar partner_opportunities faltantes (Insper, Behring) + institutions
--      Padrão: cada partner_opportunity tem uma institutions (is_partner=true)
--      de mesmo nome. Idempotente (por nome).
-- ---------------------------------------------------------------------------
INSERT INTO public.institutions (name, is_partner)
SELECT v.name, true
FROM (VALUES ('Insper'), ('Fundação Behring')) AS v(name)
WHERE NOT EXISTS (SELECT 1 FROM public.institutions i WHERE i.name = v.name);

INSERT INTO public.partner_opportunities (institution_id, name, opportunity_type, status)
SELECT i.id, i.name, 'programa de bolsa', 'inactive'
FROM public.institutions i
WHERE i.name IN ('Insper', 'Fundação Behring')
  AND NOT EXISTS (SELECT 1 FROM public.partner_opportunities po WHERE po.name = i.name);

-- ---------------------------------------------------------------------------
-- 3) Backfill: vincular documentos de parceiro às suas oportunidades (idempotente)
-- ---------------------------------------------------------------------------
UPDATE public.knowledge_documents kd
SET partner_id = po.id
FROM public.partner_opportunities po
WHERE kd.partner_id IS DISTINCT FROM po.id
  AND (
    (po.name = 'BIP Impulsiona'   AND kd.storage_path = 'documents/1781465432669_regulamento_bip_impulsiona.md') OR
    (po.name = 'Insper'           AND kd.storage_path = 'documents/1776968975352_edital_processo_seletivo_insper_20262.md') OR
    (po.name = 'Fundação Behring' AND kd.storage_path = 'documents/1774649670990_edital_fundacao_behring.md')
  );

-- ---------------------------------------------------------------------------
-- 4) Prompt da Cloudinha: adicionar regra de routing para a BASE DE CONHECIMENTO
--    (hoje inexistente). Idempotente: só injeta se ainda não estiver presente.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_anchor text := E'### Pergunta sobre PARCEIROS ou OPORTUNIDADES DE PARCEIROS?\n→ Use `query_educational_catalog` em `partners` e/ou `partner_opportunities`';
  v_block  text;
BEGIN
  v_block := v_anchor || E'\n\n### Pergunta sobre EDITAIS, REGRAS, DOCUMENTOS ou COMO FUNCIONA um programa (ProUni, Sisu, parceiros)?\n'
    || E'→ 1) Encontre o documento em `knowledge_documents` via `query_educational_catalog` (filtre por `title`/`description` com ILIKE ou pelas keywords). Pegue o `storage_path`.\n'
    || E'→ 2) Para documentos de um parceiro específico, junte `knowledge_documents.partner_id = partner_opportunities.id` (ex.: BIP Impulsiona) para achar o doc certo.\n'
    || E'→ 3) Leia o conteúdo com `download_knowledge_document(storage_path)`. É OBRIGATÓRIO ler o documento antes de responder sobre regras/critérios/prazos — nunca responda de cabeça.';

  UPDATE public.agent_prompts
  SET system_instruction = replace(system_instruction, v_anchor, v_block)
  WHERE agent_key = 'cloudinha_react'
    AND position('### Pergunta sobre EDITAIS, REGRAS' IN system_instruction) = 0
    AND position(v_anchor IN system_instruction) > 0;
END $$;
