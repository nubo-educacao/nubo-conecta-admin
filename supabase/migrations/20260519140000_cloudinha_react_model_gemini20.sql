-- Migration: switch cloudinha_react model to gemini-2.0-flash
-- Reason: gemini-2.5-flash thinking mode returns tool calls as content[].functionCall
-- with thoughtSignature instead of tool_calls[], which LangGraph toolsCondition cannot route.
-- gemini-2.0-flash does not use thinking and returns standard tool_calls format.

UPDATE agent_prompts
SET model = 'gemini-2.0-flash'
WHERE agent_key = 'cloudinha_react';
