-- Migration: set model to gemini-2.5-flash (final)
-- thinking is disabled at SDK level via thinkingConfig.thinkingBudget=0
-- supported in @langchain/google-genai ^2.x

UPDATE agent_prompts
SET model = 'gemini-2.5-flash'
WHERE agent_key = 'cloudinha_react';
