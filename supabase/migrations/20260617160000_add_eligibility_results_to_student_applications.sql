-- add_eligibility_results_to_student_applications.sql
-- ==================================================
-- Add eligibility_results column to student_applications
-- so eligibility data is available directly from application

ALTER TABLE "public"."student_applications"
ADD COLUMN IF NOT EXISTS "eligibility_results" jsonb DEFAULT NULL;

-- Backfill eligibility_results from user_profiles where available
UPDATE "public"."student_applications" sa
SET eligibility_results = up.eligibility_results
FROM "public"."user_profiles" up
WHERE sa.user_id = up.id
  AND up.eligibility_results IS NOT NULL
  AND sa.eligibility_results IS NULL;
