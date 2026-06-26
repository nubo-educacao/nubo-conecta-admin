-- =============================================================================
-- Migration: RPC execute_readonly_query
-- Permite ao MCP Server executar queries SQL read-only no catálogo educacional.
-- Usada pelas tools search_educational_catalog e describe_catalog_schema.
-- SEGURANÇA: SET TRANSACTION READ ONLY impede qualquer mutação.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.execute_readonly_query(query_text text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result jsonb;
BEGIN
  -- Forçar modo read-only — qualquer INSERT/UPDATE/DELETE será rejeitado
  SET TRANSACTION READ ONLY;

  -- Executar a query e converter resultado para JSON
  EXECUTE format('SELECT jsonb_agg(row_to_json(t)) FROM (%s) t', query_text)
    INTO result;

  RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- Permitir chamada via PostgREST (service_role usa SECURITY DEFINER)
GRANT EXECUTE ON FUNCTION public.execute_readonly_query(text) TO service_role;

COMMENT ON FUNCTION public.execute_readonly_query IS
  'Executa query SQL read-only. Usada pelo MCP Server para buscas no catálogo educacional.';
