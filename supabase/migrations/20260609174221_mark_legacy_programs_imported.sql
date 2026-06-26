-- Migration: mark_legacy_programs_imported
-- Propósito: Marcar os programas legados no ambiente de dev como is_fully_imported = true
-- para que eles apareçam na listagem de "Ciclo Anterior" no painel admin imediatamente.

UPDATE public.programs 
SET is_fully_imported = true
WHERE status != 'inactive';
