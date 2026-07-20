-- Migration: knowledge_document_opportunities — N:N entre knowledge_documents e partner_opportunities
--
-- Hoje knowledge_documents.partner_id é uma FK singular (1 documento : 1 oportunidade).
-- Um mesmo edital pode servir a mais de uma oportunidade da mesma instituição — ex.:
-- "Edital Insper 2027.1" descreve o processo seletivo comum a "Bolsa Integral do Insper"
-- e "Bolsa Parcial do Insper", mas hoje só pode estar linkado a uma delas, deixando a
-- outra sem nenhum documento na Base de Conhecimento.
--
-- knowledge_documents.partner_id é mantido por enquanto (coluna legada) até a UI migrar
-- de vez para N:N e o RPC parar de depender dela — dropar em migration futura separada.

-- 1. Tabela de junção
CREATE TABLE IF NOT EXISTS knowledge_document_opportunities (
  document_id UUID NOT NULL REFERENCES knowledge_documents(id) ON DELETE CASCADE,
  partner_opportunity_id UUID NOT NULL REFERENCES partner_opportunities(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (document_id, partner_opportunity_id)
);

CREATE INDEX IF NOT EXISTS idx_knowledge_document_opportunities_opportunity
  ON knowledge_document_opportunities (partner_opportunity_id);

ALTER TABLE knowledge_document_opportunities ENABLE ROW LEVEL SECURITY;

-- Leitura pública: só documentos ativos vinculados a oportunidades em status público
-- (mesmo padrão de knowledge_documents/partner_opportunities).
CREATE POLICY "knowledge_document_opportunities_select_public"
  ON knowledge_document_opportunities
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM knowledge_documents kd
      WHERE kd.id = document_id AND kd.is_active = true
    )
    AND EXISTS (
      SELECT 1 FROM partner_opportunities po
      WHERE po.id = partner_opportunity_id AND po.status = 'approved'
    )
  );

-- Escrita: admin autenticado com a mesma permissão usada em manage_knowledge_document.
CREATE POLICY "knowledge_document_opportunities_admin_manage"
  ON knowledge_document_opportunities
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_permissions
      WHERE user_id = auth.uid() AND permission = 'Conhecimento'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.user_permissions
      WHERE user_id = auth.uid() AND permission = 'Conhecimento'
    )
  );

-- 2. Backfill: 1:1 existente vira a primeira linha da N:N
INSERT INTO knowledge_document_opportunities (document_id, partner_opportunity_id)
SELECT id, partner_id FROM knowledge_documents WHERE partner_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- 3. Data fix pontual: "Edital Insper 2027.1" cobre o processo seletivo comum às duas
-- bolsas do Insper — hoje só linkado à Bolsa Integral (via partner_id). Linka também a
-- Bolsa Parcial, que até aqui não tinha nenhum documento de Base de Conhecimento.
INSERT INTO knowledge_document_opportunities (document_id, partner_opportunity_id)
VALUES ('c8840e25-b2ed-4104-b314-0c252be2cc71', '26625dc2-5dec-4e8f-8eef-8d570c2d0f98')
ON CONFLICT DO NOTHING;

-- 4. RPC manage_knowledge_document: adiciona p_partner_opportunity_ids (novo, N:N) mantendo
-- p_partner_id (legado) para não quebrar chamadas existentes durante a transição. Quando
-- p_partner_opportunity_ids é informado, ele é a fonte de verdade — sincroniza a tabela de
-- junção; quando omitido, o comportamento 1:1 anterior é preservado.
CREATE OR REPLACE FUNCTION public.manage_knowledge_document(
  p_id uuid DEFAULT NULL::uuid,
  p_title text DEFAULT NULL::text,
  p_description text DEFAULT NULL::text,
  p_category_id uuid DEFAULT NULL::uuid,
  p_partner_id uuid DEFAULT NULL::uuid,
  p_storage_path text DEFAULT NULL::text,
  p_is_active boolean DEFAULT NULL::boolean,
  p_keywords text[] DEFAULT NULL::text[],
  p_change_summary text DEFAULT NULL::text,
  p_delete boolean DEFAULT false,
  p_partner_opportunity_ids uuid[] DEFAULT NULL::uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_user_id UUID;
    v_doc RECORD;
    v_new_id UUID;
    v_new_version INTEGER;
BEGIN
    -- Auth check: caller must be admin
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.user_permissions WHERE user_id = v_user_id AND permission = 'Conhecimento') THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Insufficient permissions');
    END IF;

    -- DELETE
    IF p_delete AND p_id IS NOT NULL THEN
        DELETE FROM public.knowledge_documents WHERE id = p_id;
        RETURN jsonb_build_object('status', 'success', 'action', 'deleted', 'id', p_id);
    END IF;

    -- UPDATE
    IF p_id IS NOT NULL THEN
        -- Fetch current state for versioning
        SELECT * INTO v_doc FROM public.knowledge_documents WHERE id = p_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('status', 'error', 'message', 'Document not found');
        END IF;

        -- Save current version to history before updating
        v_new_version := v_doc.current_version + 1;

        INSERT INTO public.knowledge_document_versions (document_id, version_number, storage_path, change_summary, created_by)
        VALUES (p_id, v_new_version, COALESCE(p_storage_path, v_doc.storage_path), p_change_summary, v_user_id);

        -- Update document
        UPDATE public.knowledge_documents SET
            title = COALESCE(p_title, title),
            description = COALESCE(p_description, description),
            category_id = COALESCE(p_category_id, category_id),
            partner_id = p_partner_id,  -- Allow setting to NULL
            storage_path = COALESCE(p_storage_path, storage_path),
            is_active = COALESCE(p_is_active, is_active),
            current_version = v_new_version,
            updated_at = now()
        WHERE id = p_id;

        -- Update keywords if provided
        IF p_keywords IS NOT NULL THEN
            DELETE FROM public.knowledge_keywords WHERE document_id = p_id;
            INSERT INTO public.knowledge_keywords (document_id, keyword)
            SELECT p_id, LOWER(TRIM(kw)) FROM unnest(p_keywords) AS kw
            WHERE TRIM(kw) <> '';
        END IF;

        -- Sync N:N opportunities if provided
        IF p_partner_opportunity_ids IS NOT NULL THEN
            DELETE FROM public.knowledge_document_opportunities WHERE document_id = p_id;
            INSERT INTO public.knowledge_document_opportunities (document_id, partner_opportunity_id)
            SELECT p_id, opp_id FROM unnest(p_partner_opportunity_ids) AS opp_id
            ON CONFLICT DO NOTHING;
        END IF;

        RETURN jsonb_build_object('status', 'success', 'action', 'updated', 'id', p_id, 'version', v_new_version);
    END IF;

    -- CREATE
    IF p_title IS NOT NULL AND p_storage_path IS NOT NULL THEN
        INSERT INTO public.knowledge_documents (title, description, category_id, partner_id, storage_path, created_by)
        VALUES (p_title, p_description, p_category_id, p_partner_id, p_storage_path, v_user_id)
        RETURNING id INTO v_new_id;

        -- Save version 1
        INSERT INTO public.knowledge_document_versions (document_id, version_number, storage_path, change_summary, created_by)
        VALUES (v_new_id, 1, p_storage_path, 'Versão inicial', v_user_id);

        -- Insert keywords
        IF p_keywords IS NOT NULL THEN
            INSERT INTO public.knowledge_keywords (document_id, keyword)
            SELECT v_new_id, LOWER(TRIM(kw)) FROM unnest(p_keywords) AS kw
            WHERE TRIM(kw) <> '';
        END IF;

        -- Insert N:N opportunities
        IF p_partner_opportunity_ids IS NOT NULL THEN
            INSERT INTO public.knowledge_document_opportunities (document_id, partner_opportunity_id)
            SELECT v_new_id, opp_id FROM unnest(p_partner_opportunity_ids) AS opp_id
            ON CONFLICT DO NOTHING;
        END IF;

        RETURN jsonb_build_object('status', 'success', 'action', 'created', 'id', v_new_id);
    END IF;

    RETURN jsonb_build_object('status', 'error', 'message', 'Invalid parameters: title and storage_path required for creation');
END;
$function$;

-- 5. RPC get_knowledge_documents: passa a agregar todas as oportunidades vinculadas
-- (partner_opportunities_list), mantendo partner_id/partner_name (legado, primeira/única
-- oportunidade no caso 1:1) para não quebrar consumidores existentes.
CREATE OR REPLACE FUNCTION public.get_knowledge_documents(
  p_category_id uuid DEFAULT NULL::uuid,
  p_partner_id uuid DEFAULT NULL::uuid,
  p_is_active boolean DEFAULT NULL::boolean
)
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
            ), '[]'::jsonb),
            'partner_opportunities', COALESCE((
                SELECT jsonb_agg(jsonb_build_object('id', po.id, 'name', po.name))
                FROM public.knowledge_document_opportunities kdo
                JOIN public.partner_opportunities po ON po.id = kdo.partner_opportunity_id
                WHERE kdo.document_id = kd.id
            ), '[]'::jsonb)
        ) AS row_data
        FROM public.knowledge_documents kd
        LEFT JOIN public.knowledge_categories kc ON kd.category_id = kc.id
        LEFT JOIN public.partner_opportunities p ON kd.partner_id = p.id
        WHERE (p_category_id IS NULL OR kd.category_id = p_category_id)
          AND (
            p_partner_id IS NULL
            OR kd.partner_id = p_partner_id
            OR EXISTS (
                SELECT 1 FROM public.knowledge_document_opportunities kdo
                WHERE kdo.document_id = kd.id AND kdo.partner_opportunity_id = p_partner_id
            )
          )
          AND (p_is_active IS NULL OR kd.is_active = p_is_active)
    ) sub;

    RETURN COALESCE(v_results, '[]'::jsonb);
END;
$function$;
