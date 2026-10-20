-- Remove SÓ a massa de QA da Sprint 9.0 (qa_seed.sql). Identificação:
-- UUIDs 5e9a0000-…, títulos/nomes "[QA-S9]", anônimos "qa-s9-anon-*",
-- e-mails @qa-s9.invalid. Nada mais é tocado. Só DEV verificado por identidade QA e conjunto de jobs.
DO $$ BEGIN
  IF (SELECT count(*) FROM public.user_profiles)>1000 OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id='781fe878-3d24-4061-8496-ac0ef3b627a5' AND email='backoffice@qa-s9.invalid') OR NOT coalesce((SELECT array_agg(jobname ORDER BY jobname) IN (ARRAY['check-program-deadlines']::text[],ARRAY['check-program-deadlines','user-activity-days-daily']::text[]) FROM cron.job),false) THEN RAISE EXCEPTION 'QA_S9_ABORT: alvo não é o DEV'; END IF;
END $$;

DO $ BEGIN
 IF to_regclass('public.conversion_match_links') IS NOT NULL THEN
 DELETE FROM public.conversion_match_links WHERE user_id::text LIKE '5e9a0000-%';
 DELETE FROM public.user_activity_days WHERE user_id::text LIKE '5e9a0000-%';
 END IF;
END $;
DELETE FROM public.admin_alerts
 WHERE entity_id IN (SELECT id::text FROM public.important_dates WHERE id::text LIKE '5e9a0000-%' AND title LIKE '[QA-S9]%');
DELETE FROM public.important_dates WHERE id::text LIKE '5e9a0000-%' AND title LIKE '[QA-S9]%';
DELETE FROM public.engagement_events WHERE user_id::text LIKE '5e9a0000-%' OR anonymous_id LIKE 'qa-s9-anon-%';
DELETE FROM public.student_applications WHERE user_id::text LIKE '5e9a0000-%';
DELETE FROM public.user_opportunity_matches WHERE profile_id::text LIKE '5e9a0000-%';
DELETE FROM public.user_favorites WHERE user_id::text LIKE '5e9a0000-%';
DELETE FROM public.chat_messages WHERE user_id::text LIKE '5e9a0000-%';
DELETE FROM public.user_attribution WHERE user_id::text LIKE '5e9a0000-%';
DELETE FROM public.user_income WHERE user_id::text LIKE '5e9a0000-%';
DELETE FROM public.user_preferences WHERE user_id::text LIKE '5e9a0000-%';
DELETE FROM public.user_profiles WHERE id::text LIKE '5e9a0000-%';
DELETE FROM auth.users WHERE id::text LIKE '5e9a0000-%' AND email LIKE '%@qa-s9.invalid';
DELETE FROM public.channel_links WHERE id::text LIKE '5e9a0000-%' AND code LIKE 'qa-s9-%';
DELETE FROM public.channels WHERE id::text LIKE '5e9a0000-%' AND slug LIKE 'qa-s9-%';
DELETE FROM public.campaigns WHERE id::text LIKE '5e9a0000-%' AND slug LIKE 'qa-s9-%';
