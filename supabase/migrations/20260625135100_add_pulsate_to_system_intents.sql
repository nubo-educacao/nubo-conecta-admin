-- 20260625135100_add_pulsate_to_system_intents.sql
-- Add pulsate column to system_intents and update step_change intent

ALTER TABLE public.system_intents 
ADD COLUMN pulsate BOOLEAN DEFAULT false;

COMMENT ON COLUMN public.system_intents.pulsate IS 'Se true, a Cloudinha apenas pulsa/notifica sem abrir o drawer automaticamente.';

-- Update step_change intent (added via database/admin dashboard)
UPDATE public.system_intents
SET pulsate = true, open_drawer = false
WHERE id = '8148fc9f-8173-485c-88e0-09f88ab939bc';
