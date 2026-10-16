-- Fecha EXECUTE anônimo nas RPCs legadas de tracking (TP-2 / NUB-RD-77b).
--
-- Em produção (conferido em 2026-10-15) as três são SECURITY DEFINER com EXECUTE
-- para PUBLIC e anon. get_admin_funnel_users e get_partner_redirect_users não têm
-- guard interno: a chave anon pública lia a listagem de usuários.
--
-- * get_student_details_v2: sem consumidor em admin, app ou cloudinha e sem
--   dependência SQL. Fica só para service_role até o contract decidir o DROP.
-- * get_admin_funnel_users e get_partner_redirect_users: em uso pelo admin com
--   sessão autenticada. Só PUBLIC/anon perdem EXECUTE; o guard de permissão vem
--   com a PR do TP-2 (redirect users) e a aposentadoria do TP-5 (funnel users).
--
-- Idempotente e tolerante a função ausente (get_student_details_v2 não existe no DEV).

DO $$
DECLARE
  v_sig text;
BEGIN
  IF to_regprocedure('public.get_student_details_v2(uuid)') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION public.get_student_details_v2(uuid) FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION public.get_student_details_v2(uuid) TO service_role;
  END IF;

  FOREACH v_sig IN ARRAY ARRAY[
    'public.get_admin_funnel_users()',
    'public.get_partner_redirect_users(uuid)'
  ] LOOP
    IF to_regprocedure(v_sig) IS NOT NULL THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', v_sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', v_sig);
    END IF;
  END LOOP;
END $$;
