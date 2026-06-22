-- Migration: Blindar execute_readonly_query e reforçar regras de SQL no prompt
-- Data: 2026-06-18
-- Contexto (agent_turns): a Cloudinha falhava em queries por:
--   1) ponto-e-vírgula final → a RPC embrulha como `SELECT ... FROM (<sql>) t`,
--      então `;` causa "syntax error at or near ';'".
--   2) coluna inexistente em knowledge_documents (usava `category`, é `category_id`).

-- ---------------------------------------------------------------------------
-- A) execute_readonly_query: remover `;` final (e espaços) antes de embrulhar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.execute_readonly_query(query_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  result jsonb;
  v_query text;
BEGIN
  -- Forçar modo read-only — qualquer INSERT/UPDATE/DELETE será rejeitado
  SET TRANSACTION READ ONLY;

  -- Normalizar: tirar espaços nas pontas e ponto-e-vírgula(s) final(is),
  -- que quebram o embrulho `FROM (<query>) t`.
  v_query := rtrim(btrim(query_text), ';');

  EXECUTE format('SELECT jsonb_agg(row_to_json(t)) FROM (%s) t', v_query)
    INTO result;

  RETURN COALESCE(result, '[]'::jsonb);
END;
$function$;