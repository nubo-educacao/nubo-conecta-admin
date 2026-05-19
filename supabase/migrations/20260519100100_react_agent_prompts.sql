-- 20260519100100_react_agent_prompts.sql
-- Sprint 12.0: Migração ReAct — adaptar agent_prompts para agente unificado cloudinha_react
-- ADR-0011: De 3 rows (planning/reasoning/response) para 1 row (cloudinha_react)

-- Step M.2: Garantir que UNIQUE constraint existe em agent_key
-- (já criada em 20260407100000, mas garantindo idempotência)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'agent_prompts'
      AND constraint_type = 'UNIQUE'
      AND constraint_name = 'agent_prompts_agent_key_key'
  ) THEN
    ALTER TABLE public.agent_prompts
      ADD CONSTRAINT agent_prompts_agent_key_unique UNIQUE (agent_key);
  END IF;
END $$;

-- Step M.2: Adicionar campos model e max_steps (se não existirem)
ALTER TABLE public.agent_prompts
  ADD COLUMN IF NOT EXISTS model     TEXT    DEFAULT 'gemini-2.5-flash',
  ADD COLUMN IF NOT EXISTS max_steps INTEGER DEFAULT 5;

COMMENT ON COLUMN public.agent_prompts.model IS 'Model ID do Google GenAI usado por este agente (ex: gemini-2.5-flash).';
COMMENT ON COLUMN public.agent_prompts.max_steps IS 'Número máximo de iterações do loop ReAct antes de forçar resposta final.';

-- Step M.2: Desativar rows do pipeline legado
UPDATE public.agent_prompts
SET is_active = false
WHERE agent_key IN ('planning', 'reasoning', 'response');

-- Step M.2: Inserir (ou atualizar) row do agente ReAct unificado
INSERT INTO public.agent_prompts (agent_key, system_instruction, temperature, is_active, model, max_steps)
VALUES (
  'cloudinha_react',
  '-- SYSTEM PROMPT PLACEHOLDER (será preenchido pelo PM via /agent-config) --',
  0.7,
  true,
  'gemini-2.5-flash',
  5
)
ON CONFLICT (agent_key) DO UPDATE SET
  is_active  = true,
  model      = EXCLUDED.model,
  max_steps  = EXCLUDED.max_steps,
  updated_at = now();

-- Step M.3: agent_errors — sem alteração de schema necessária.
-- O campo error_type é TEXT (confirmado na auditoria). Novos valores utilizados pelo código:
--   react_loop_error    — erro genérico no loop ReAct
--   max_steps_exceeded  — agente atingiu limite de iterações
--   tool_timeout        — ferramenta excedeu timeout
--   tool_error          — erro na execução da ferramenta (mantido)
--   tool_empty_result   — ferramenta retornou vazio (mantido)
-- Nenhum ALTER TABLE necessário — herda policies de RLS existentes.
