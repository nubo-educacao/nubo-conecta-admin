-- Migration: set model to gemini-1.5-flash for cloudinha_react
-- Reason: gemini-2.5-flash thinking mode returns tool calls as content[].functionCall
-- with thoughtSignature which LangGraph toolsCondition cannot detect (checks tool_calls[]).
-- gemini-1.5-flash has no thinking and returns standard tool_calls format.

UPDATE agent_prompts
SET model = 'gemini-1.5-flash'
WHERE agent_key = 'cloudinha_react';
