-- sync_eligibility_to_applications.sql
-- ====================================
-- Copy eligibility_results from user_profiles to student_applications

UPDATE "public"."student_applications" sa
SET eligibility_results = up.eligibility_results
FROM "public"."user_profiles" up
WHERE sa.user_id = up.id
  AND up.eligibility_results IS NOT NULL
  AND up.eligibility_results != '[]'::jsonb
  AND (sa.eligibility_results IS NULL OR sa.eligibility_results = '[]'::jsonb)
  AND sa.status IN ('SUBMITTED', 'redirected');
