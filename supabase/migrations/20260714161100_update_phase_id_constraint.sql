-- Migration: Update phase_id constraint to ON DELETE RESTRICT
-- This prevents deleting an opportunity phase if there are candidates currently in it.
-- We want to force the Admin/Partner to choose a fallback phase before deleting.

ALTER TABLE public.student_applications 
DROP CONSTRAINT IF EXISTS student_applications_phase_id_fkey;

ALTER TABLE public.student_applications 
ADD CONSTRAINT student_applications_phase_id_fkey 
FOREIGN KEY (phase_id) 
REFERENCES public.opportunity_phases(id) 
ON DELETE RESTRICT;
