-- Migration: revert model to gemini-2.5-flash (gemini-2.0-flash deprecated for new accounts)
-- Thinking is disabled at the SDK level via generationConfig.thinkingConfig.thinkingBudget=0

UPDATE agent_prompts
SET model = 'gemini-2.5-flash'
WHERE agent_key = 'cloudinha_react';
