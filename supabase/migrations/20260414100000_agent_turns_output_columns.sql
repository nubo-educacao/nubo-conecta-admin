-- Sprint 5 Plano A: Adicionar colunas de output e custo em agent_turns
ALTER TABLE public.agent_turns
  ADD COLUMN IF NOT EXISTS planning_output  TEXT,
  ADD COLUMN IF NOT EXISTS reasoning_output TEXT,
  ADD COLUMN IF NOT EXISTS response_output  TEXT,
  ADD COLUMN IF NOT EXISTS estimated_cost_usd NUMERIC(10,6);

CREATE INDEX IF NOT EXISTS idx_agent_turns_session_created
  ON public.agent_turns(session_id, created_at DESC);

COMMENT ON COLUMN public.agent_turns.planning_output    IS 'Texto bruto produzido pelo Planning Agent (markdown estruturado).';
COMMENT ON COLUMN public.agent_turns.reasoning_output   IS 'Texto bruto produzido pelo Reasoning Agent (relatório markdown).';
COMMENT ON COLUMN public.agent_turns.response_output    IS 'Texto final enviado ao usuário pelo Response Agent.';
COMMENT ON COLUMN public.agent_turns.estimated_cost_usd IS 'Custo estimado do turno em USD com base nos tokens consumidos.';
