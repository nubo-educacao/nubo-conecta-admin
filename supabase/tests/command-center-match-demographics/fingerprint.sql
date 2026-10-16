-- Somente leitura. Rodar antes e depois de run_dev.sh: os hashes devem ser
-- idênticos (fixtures e DDL do teste não persistem). Devolve só contagens e
-- hashes, nunca linhas.
SELECT 'user_profiles' AS t, count(*) AS n, md5(coalesce(string_agg(x::text, ',' ORDER BY x.id), '')) AS h FROM public.user_profiles x
UNION ALL SELECT 'user_preferences', count(*), md5(coalesce(string_agg(x::text, ',' ORDER BY x.id), '')) FROM public.user_preferences x
UNION ALL SELECT 'user_income', count(*), md5(coalesce(string_agg(x::text, ',' ORDER BY x.id), '')) FROM public.user_income x
UNION ALL SELECT 'user_opportunity_matches', count(*), md5(coalesce(string_agg(x::text, ',' ORDER BY x.id), '')) FROM public.user_opportunity_matches x
UNION ALL SELECT 'student_applications', count(*), md5(coalesce(string_agg(x::text, ',' ORDER BY x.id), '')) FROM public.student_applications x
UNION ALL SELECT 'partner_forms', count(*), md5(coalesce(string_agg(x::text, ',' ORDER BY x.id), '')) FROM public.partner_forms x
UNION ALL SELECT 'chat_messages', count(*), md5(coalesce(string_agg(x::text, ',' ORDER BY x.id), '')) FROM public.chat_messages x
UNION ALL SELECT 'auth.users', count(*), md5(coalesce(string_agg(x.id::text, ',' ORDER BY x.id), '')) FROM auth.users x
UNION ALL SELECT 'objects:views', count(*), string_agg(c.relname, ',') FROM pg_class c WHERE c.relname IN ('vw_user_match_evidence','vw_user_demographics_resolved')
UNION ALL SELECT 'rpc_md5', 1, md5(regexp_replace(pg_get_functiondef('public.get_command_center_demographics()'::regprocedure), '\s', '', 'g'));
