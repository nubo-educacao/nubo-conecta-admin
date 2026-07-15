-- Migration: add ui_component to partner_forms
ALTER TABLE public.partner_forms ADD COLUMN ui_component VARCHAR(50);

COMMENT ON COLUMN public.partner_forms.ui_component IS 'Tipo de componente de UI do input (ex. textarea, cpf_input, phone_input, etc)';
