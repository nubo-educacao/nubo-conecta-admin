-- Debug query to check if backfill worked
-- Run this in Supabase SQL Editor

-- 1. Check if eligibility_results was saved in user_profiles
SELECT
  id,
  full_name,
  eligibility_results,
  updated_at
FROM public.user_profiles
WHERE eligibility_results IS NOT NULL
LIMIT 10;

-- 2. Check a specific student_application to see what data should have been mapped
SELECT
  sa.id,
  sa.user_id,
  sa.status,
  sa.answers,
  up.full_name,
  up.eligibility_results
FROM public.student_applications sa
LEFT JOIN public.user_profiles up ON sa.user_id = up.id
WHERE sa.status IN ('SUBMITTED', 'redirected')
LIMIT 5;

-- 3. Check partner_forms to see mapping_source values
SELECT
  id,
  partner_id,
  field_name,
  mapping_source,
  is_criterion
FROM public.partner_forms
WHERE partner_id IN (
  SELECT DISTINCT partner_id
  FROM public.student_applications
  WHERE status IN ('SUBMITTED', 'redirected')
)
LIMIT 20;
