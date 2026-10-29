-- Fecha EXECUTE anônimo nas RPCs de ETL (public.etl_*).
--
-- Em produção (conferido em 2026-10-29) as 12 sobrecargas abaixo têm EXECUTE
-- para PUBLIC e anon; todas menos etl_import_sisu_vacancies(uuid,int,int,uuid)
-- são SECURITY DEFINER. Com a chave anon pública dava para clonar ciclo,
-- reverter (apagar) importações, parar runs e reimportar ProUni/SiSU/e-MEC.
--
--   etl_clone_prouni_cycle(uuid,uuid)
--   etl_import_emec()                      etl_import_emec(int,int,uuid)
--   etl_import_prouni(uuid,int,text,uuid)  etl_import_refresh_opportunities()
--   etl_import_sisu(uuid)                  etl_import_sisu(uuid,int,int,uuid)
--   etl_import_sisu_vacancies(uuid)        etl_import_sisu_vacancies(uuid,int,int,uuid)
--   etl_reap_stale_runs(interval)          etl_rollback_log(uuid,int,uuid)
--   etl_stop_log(uuid)
--
-- O admin chama essas RPCs com a sessão do usuário (etlPipelineService), então
-- authenticated mantém EXECUTE; service_role também. Varre pg_proc em vez de
-- listar assinaturas para pegar toda sobrecarga existente no ambiente
-- (etl_clone_sisu_cycle, da PR #91, já nasce com o mesmo ACL).
--
-- Ainda falta o guard interno (service_role OR is_backoffice_admin()): com só
-- este REVOKE, qualquer JWT autenticado do projeto continua executando.
--
-- Idempotente.

DO $$
DECLARE
  v_fn regprocedure;
BEGIN
  FOR v_fn IN
    SELECT p.oid::regprocedure
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname LIKE 'etl\_%'
       AND p.prokind = 'f'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', v_fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', v_fn);
  END LOOP;

  IF EXISTS (
    SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname LIKE 'etl\_%'
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'public.etl_* ainda executável por anon';
  END IF;
END $$;
