-- Migration: Create few_shot_examples table
-- Sprint 13.0 — Card: Backoffice: Criação e Configuração de Few-Shot Examples

CREATE TABLE few_shot_examples (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  starter_id UUID REFERENCES cloudinha_starters(id) ON DELETE SET NULL,
  category TEXT NOT NULL DEFAULT 'geral',
  user_message TEXT NOT NULL,
  expected_tools JSONB DEFAULT '[]'::jsonb,
  expected_response TEXT NOT NULL,
  is_active BOOLEAN DEFAULT true,
  sort_order INT DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_few_shot_active ON few_shot_examples(is_active) WHERE is_active = true;
CREATE INDEX idx_few_shot_starter ON few_shot_examples(starter_id);

-- RLS
ALTER TABLE few_shot_examples ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin full access" ON few_shot_examples
  FOR ALL USING (
    EXISTS (SELECT 1 FROM user_permissions WHERE user_id = auth.uid() AND role = 'admin')
  );

-- Grant read to all authenticated/anon (agent reads this)
GRANT SELECT ON few_shot_examples TO anon, authenticated;
