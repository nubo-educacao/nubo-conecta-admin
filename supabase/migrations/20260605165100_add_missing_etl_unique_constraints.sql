-- Add missing unique constraints required by year-agnostic ETL pipeline ON CONFLICT clauses
-- 20260605165100_add_missing_etl_unique_constraints.sql

ALTER TABLE public.campus 
  ADD CONSTRAINT campus_institution_id_name_city_key UNIQUE (institution_id, name, city);

ALTER TABLE public.opportunities 
  ADD CONSTRAINT opportunities_course_type_year_semester_shift_key UNIQUE (course_id, opportunity_type, year, semester, shift);
