-- 20260406100400_create_agent_turns.sql
-- Sprint 3: Auditoria end-to-end do pipeline Planning→Reasoning→Response

CREATE TABLE public.agent_turns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id),
    session_id TEXT,
    planning_latency_ms INT,
    reasoning_latency_ms INT,
    response_latency_ms INT,
    total_latency_ms INT,
    input_tokens INT,
    output_tokens INT,
    tools_used JSONB,
    intent_category TEXT,
    reasoning_report TEXT,
    action TEXT DEFAULT 'none',
    created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.agent_turns IS 'Telemetria end-to-end de cada turno cognitivo da Cloudinha. Cada linha = 1 ciclo Planning→Reasoning→Response.';

CREATE INDEX idx_agent_turns_user ON public.agent_turns(user_id);
CREATE INDEX idx_agent_turns_session ON public.agent_turns(session_id);
CREATE INDEX idx_agent_turns_created ON public.agent_turns(created_at DESC);
