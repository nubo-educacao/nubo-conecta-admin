-- Migration: fix_is_fully_imported_flags
-- Purpose: Correct the `is_fully_imported` flag on programs to only be true if data actually exists.

-- Reset all programs
UPDATE public.programs SET is_fully_imported = false;

-- SiSU: Mark true if there are cutoff scores (meaning Base was imported)
UPDATE public.programs p
SET is_fully_imported = true
WHERE p.type = 'sisu' AND EXISTS (
  SELECT 1 FROM public.opportunities o
  WHERE o.opportunity_type = 'sisu' 
    AND o.year = p.cycle_year 
    AND o.semester = p.cycle_semester
    AND o.cutoff_score IS NOT NULL
);

-- ProUni: Mark true if there is occupation data (meaning Ocupadas was imported)
UPDATE public.programs p
SET is_fully_imported = true
WHERE p.type = 'prouni' AND EXISTS (
  SELECT 1 FROM public.courses_prouni_vacancies pv
  WHERE pv.year = p.cycle_year 
    AND pv.semester = p.cycle_semester
    AND pv.bolsas_ampla_ocupada IS NOT NULL
);
