-- agent_prompt_versions: histórico/auditoria dos prompts de agentes.
-- Fonte da verdade do prompt = BACKOFFICE (edita agent_prompts). Esta tabela dá
-- rastreio e rollback. A captura é AUTOMÁTICA via trigger: toda vez que
-- agent_prompts muda (system_instruction/model/max_steps/temperature), a versão
-- ANTERIOR é gravada aqui — independe de qual caminho fez o UPDATE.

CREATE TABLE IF NOT EXISTS agent_prompt_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_prompt_id uuid REFERENCES agent_prompts(id) ON DELETE CASCADE,
    agent_key text NOT NULL,
    system_instruction text,
    model text,
    max_steps integer,
    temperature numeric,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agent_prompt_versions_key
    ON agent_prompt_versions (agent_key, created_at DESC);

CREATE OR REPLACE FUNCTION snapshot_agent_prompt_version()
RETURNS trigger AS $$
BEGIN
    IF NEW.system_instruction IS DISTINCT FROM OLD.system_instruction
       OR NEW.model IS DISTINCT FROM OLD.model
       OR NEW.max_steps IS DISTINCT FROM OLD.max_steps
       OR NEW.temperature IS DISTINCT FROM OLD.temperature THEN
        INSERT INTO agent_prompt_versions (
            agent_prompt_id, agent_key, system_instruction, model, max_steps, temperature, created_at
        ) VALUES (
            OLD.id, OLD.agent_key, OLD.system_instruction, OLD.model, OLD.max_steps, OLD.temperature,
            COALESCE(OLD.updated_at, now())
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_snapshot_agent_prompt_version ON agent_prompts;
CREATE TRIGGER trg_snapshot_agent_prompt_version
    BEFORE UPDATE ON agent_prompts
    FOR EACH ROW EXECUTE FUNCTION snapshot_agent_prompt_version();

-- RLS: alinhar com agent_prompts (somente usuários autenticados do admin leem/escrevem).
ALTER TABLE agent_prompt_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "agent_prompt_versions_select_authenticated" ON agent_prompt_versions;
CREATE POLICY "agent_prompt_versions_select_authenticated"
    ON agent_prompt_versions FOR SELECT
    TO authenticated USING (true);
