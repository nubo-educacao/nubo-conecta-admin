-- update_handle_new_user_trigger.sql
-- =====================================
-- Update handle_new_user to capture referral_source from raw_user_meta_data
-- Since the referral_source column already exists in user_profiles, we just
-- need to pass it during the INSERT.

CREATE OR REPLACE FUNCTION "public"."handle_new_user"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.user_profiles (id, referral_source)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'referral_source')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$function$;
