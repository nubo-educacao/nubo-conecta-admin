-- Called inside rollback-only test transaction, never standalone.
DO $$ BEGIN
 IF to_regclass('public.conversion_match_links') IS NOT NULL THEN
  DELETE FROM public.analytics_conversion_capture_failures WHERE user_id::text LIKE '91dd0000-%';
  DELETE FROM public.conversion_match_links WHERE user_id IN (SELECT id FROM auth.users WHERE email IN ('tpd-1@qa-s9.invalid','tpd-2@qa-s9.invalid','tpd-3@qa-s9.invalid','tpd-4@qa-s9.invalid'));
  DELETE FROM public.user_activity_days WHERE user_id IN (SELECT id FROM auth.users WHERE email IN ('tpd-1@qa-s9.invalid','tpd-2@qa-s9.invalid'));
 END IF;
END $$;
DELETE FROM public.engagement_events WHERE event_id LIKE 'tpd-%' AND user_id::text LIKE '91dd0000-%';
DELETE FROM public.student_applications WHERE user_id::text LIKE '91dd0000-%';
DELETE FROM public.user_opportunity_matches WHERE profile_id::text LIKE '91dd0000-%';
DELETE FROM public.chat_messages WHERE user_id::text LIKE '91dd0000-%';
DELETE FROM auth.sessions WHERE user_id::text LIKE '91dd0000-%';
DELETE FROM public.user_permissions WHERE user_id::text LIKE '91dd0000-%';
DELETE FROM public.user_profiles WHERE id::text LIKE '91dd0000-%';
DELETE FROM auth.users WHERE id::text LIKE '91dd0000-%' AND email IN ('tpd-1@qa-s9.invalid','tpd-2@qa-s9.invalid');
