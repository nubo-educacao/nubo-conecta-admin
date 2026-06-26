-- 20260625152200_configure_system_intents_pulsate.sql
-- Configure system intents: tutorial and submit open the drawer, all others pulsate.

-- 1. For tutorial and submit (final de candidatura): open_drawer = true, pulsate = false
UPDATE public.system_intents
SET open_drawer = true, pulsate = false
WHERE command IN ('tutorial', 'submit');

-- 2. For all other contextual intents: open_drawer = false, pulsate = true
UPDATE public.system_intents
SET open_drawer = false, pulsate = true
WHERE command IN ('page_context', 'step_change', 'validation_error', 'welcome_back');
