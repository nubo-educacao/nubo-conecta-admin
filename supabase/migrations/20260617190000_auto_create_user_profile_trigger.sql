-- auto_create_user_profile_trigger.sql
-- =====================================
-- Guarantee every auth.users row has a matching user_profiles row.
-- Previously user_profiles was created only by the app onboarding upsert
-- (saveUserData), so users who authenticated but never finished onboarding
-- (e.g. dropped straight into a partner form) had no profile.
-- This left 1087 of 4137 auth users without a user_profiles row, which is
-- why partner-portal name/eligibility joins to user_profiles came up empty.

-- 1. Trigger function: create an empty profile on signup. SECURITY DEFINER so
--    it bypasses RLS; idempotent via ON CONFLICT.
CREATE OR REPLACE FUNCTION "public"."handle_new_user"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.user_profiles (id)
  VALUES (NEW.id)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$function$;

-- 2. Fire after every new auth user.
DROP TRIGGER IF EXISTS "on_auth_user_created" ON "auth"."users";
CREATE TRIGGER "on_auth_user_created"
  AFTER INSERT ON "auth"."users"
  FOR EACH ROW
  EXECUTE FUNCTION "public"."handle_new_user"();

-- 3. Backfill the existing orphaned auth users (no profile yet).
INSERT INTO public.user_profiles (id)
SELECT u.id
FROM auth.users u
WHERE NOT EXISTS (
  SELECT 1 FROM public.user_profiles up WHERE up.id = u.id
)
ON CONFLICT (id) DO NOTHING;
