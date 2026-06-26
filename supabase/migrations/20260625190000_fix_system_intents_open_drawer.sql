-- 20260625190000_fix_system_intents_open_drawer.sql
-- Fix: validation_error should pulsate (not open drawer) — user is mid-form
-- The drawer opening during form fill was disruptive and incorrect.

UPDATE public.system_intents
SET open_drawer = false
WHERE command = 'validation_error';

-- Confirm final state (informational comments):
-- submit:           open_drawer = true  ✓ (congratulate after candidatura)
-- tutorial:         open_drawer = true  ✓ (onboard anonymous user)
-- page_context:     open_drawer = true  on /oportunidades/:id only (configured via trigger_route)
-- validation_error: open_drawer = false ✓ (fixed — just pulsate)
-- welcome_back:     open_drawer = false ✓ (just pulsate)
-- step_change:      open_drawer = false, is_active = false (disabled)
