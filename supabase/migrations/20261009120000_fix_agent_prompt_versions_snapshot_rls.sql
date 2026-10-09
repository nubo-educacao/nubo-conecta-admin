-- =============================================================================
-- Migration: fix_agent_prompt_versions_snapshot_rls
-- O trigger trg_snapshot_agent_prompt_version (BEFORE UPDATE em agent_prompts)
-- grava a versão anterior em agent_prompt_versions. A função rodava como
-- SECURITY INVOKER e agent_prompt_versions só tem política de SELECT, então
-- qualquer UPDATE feito pelo backoffice falhava com:
--   new row violates row-level security policy for table "agent_prompt_versions"
-- Correção: a função passa a ser SECURITY DEFINER (owner ignora RLS), mantendo a
-- tabela de versões somente-leitura para clientes. Quem pode disparar o trigger
-- continua controlado pela RLS de agent_prompts (is_backoffice_admin()).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.snapshot_agent_prompt_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.system_instruction IS DISTINCT FROM OLD.system_instruction
       OR NEW.model IS DISTINCT FROM OLD.model
       OR NEW.max_steps IS DISTINCT FROM OLD.max_steps
       OR NEW.temperature IS DISTINCT FROM OLD.temperature THEN
        INSERT INTO public.agent_prompt_versions (
            agent_prompt_id, agent_key, system_instruction, model, max_steps, temperature, created_at
        ) VALUES (
            OLD.id, OLD.agent_key, OLD.system_instruction, OLD.model, OLD.max_steps, OLD.temperature,
            COALESCE(OLD.updated_at, now())
        );
    END IF;
    RETURN NEW;
END;
$$;

-- Função de trigger não deve ser chamável diretamente via RPC.
REVOKE EXECUTE ON FUNCTION public.snapshot_agent_prompt_version() FROM PUBLIC, anon, authenticated;
