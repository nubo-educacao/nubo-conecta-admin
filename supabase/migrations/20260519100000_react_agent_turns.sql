-- 20260519100000_react_agent_turns.sql
-- Sprint 12.0: Migração ReAct — adaptar agent_turns para arquitetura ReAct LangChain.js
-- ADR-0011: Remove campos do pipeline Planning→Reasoning→Response, adiciona campos do loop ReAct

-- Step M.1: Dropar campos do pipeline legado (3 fases)
ALTER TABLE public.agent_turns
  DROP COLUMN IF EXISTS planning_latency_ms,
  DROP COLUMN IF EXISTS reasoning_latency_ms,
  DROP COLUMN IF EXISTS response_latency_ms,
  DROP COLUMN IF EXISTS planning_output,
  DROP COLUMN IF EXISTS reasoning_output,
  DROP COLUMN IF EXISTS response_output,
  DROP COLUMN IF EXISTS reasoning_report;

-- Step M.1: Adicionar campos do loop ReAct
ALTER TABLE public.agent_turns
  ADD COLUMN IF NOT EXISTS model_latency_ms  INTEGER,
  ADD COLUMN IF NOT EXISTS tools_latency_ms  INTEGER,
  ADD COLUMN IF NOT EXISTS steps             JSONB DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS agent_output      TEXT;

-- Comentários de schema
COMMENT ON COLUMN public.agent_turns.steps IS 'Array of ReAct loop steps: [{thought, action: {tool, args}, observation}]';
COMMENT ON COLUMN public.agent_turns.model_latency_ms IS 'Total LLM inference time (all steps combined)';
COMMENT ON COLUMN public.agent_turns.tools_latency_ms IS 'Total tool execution time (all steps combined)';
COMMENT ON COLUMN public.agent_turns.agent_output IS 'Final unified response text from the ReAct agent';

-- Índice GIN para queries em steps JSONB
CREATE INDEX IF NOT EXISTS idx_agent_turns_steps ON public.agent_turns USING GIN (steps);
