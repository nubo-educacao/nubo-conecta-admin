-- Migration: Insert phase_updated system intent config for Cloudinha
INSERT INTO public.system_intents (command, trigger_type, open_drawer, delay_ms, trigger_message, description)
SELECT 
    'phase_updated',
    'manual',
    true,
    500,
    'Olá! Vim te contar uma novidade sobre o seu processo seletivo em {{opportunity_name}}. A sua candidatura avançou para a fase: {{phase_name}}! 🚀 O que achou dessa novidade?',
    'Notifica o aluno sobre a atualização da fase da candidatura.'
WHERE NOT EXISTS (
    SELECT 1 FROM public.system_intents WHERE command = 'phase_updated'
);
