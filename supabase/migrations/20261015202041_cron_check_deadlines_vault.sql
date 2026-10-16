-- TP-1 NUB-RD-75c / ADR-0024 — cron de prazos com configuração no Vault
-- Decisão humana registrada em 2026-10-15 (execução Snaps be8d03ae).
--
-- Estado encontrado (PROD e DEV): job 'check-program-deadlines' 0 8 * * * GMT
-- ativo, falhando todo dia desde 22/08 com "configuração ausente
-- (app.settings.supabase_url, app.settings.service_role_key)". O caminho
-- sugerido pela mensagem (ALTER DATABASE ... SET) não é suportado no Supabase
-- hospedado (postgres não é superuser) e gravaria a service_role key em
-- pg_db_role_setting.
--
-- Esta migration:
--   1. Lê URL e segredo do Supabase Vault:
--        cron_check_deadlines_url    — https://<ref>.supabase.co
--        cron_check_deadlines_secret — segredo DEDICADO (não a service_role)
--      A fonte da verdade do segredo é o Snaps project_config
--      (NUBO_CRON_DEADLINES_SECRET, por environment). A cópia no Vault é
--      provisionada por humano, fora do Git:
--        SELECT vault.create_secret('<valor>', 'cron_check_deadlines_secret');
--   2. Envia o segredo no header x-cron-secret. A Edge valida pela RPC
--      cron_deadlines_secret_status (service_role apenas) e roda com
--      verify_jwt = false.
--   3. Passa a devolver o request id do pg_net, para cruzar com
--      net._http_response (status_code/content). _http_response é efêmera
--      (TTL padrão de 6h): conferir no mesmo dia.
--   4. Cria o índice único parcial de dedupe de alertas pending.
--
-- O agendamento NÃO é tocado: o job já existe; recriá-lo arriscaria duplicar.
--
-- Rollback operacional: SELECT cron.alter_job(<jobid>, active := false);
-- ou remover o segredo do Vault (o job volta a falhar explicitamente).

-- 1. Dedupe -------------------------------------------------------------------
DO $dedupe$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM public.admin_alerts
     WHERE status = 'pending'
     GROUP BY alert_type, entity_type, entity_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION
      'admin_alerts tem pending duplicados por (alert_type, entity_type, entity_id); resolva-os antes de criar admin_alerts_pending_dedupe_uidx';
  END IF;
END
$dedupe$;

CREATE UNIQUE INDEX IF NOT EXISTS admin_alerts_pending_dedupe_uidx
  ON public.admin_alerts (alert_type, entity_type, entity_id)
  WHERE status = 'pending';

-- 2. Validação do segredo para a Edge Function ---------------------------------
CREATE OR REPLACE FUNCTION public.cron_deadlines_secret_status(p_secret text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_expected text;
BEGIN
    SELECT nullif(trim(ds.decrypted_secret), '')
      INTO v_expected
      FROM vault.decrypted_secrets ds
     WHERE ds.name = 'cron_check_deadlines_secret';

    IF v_expected IS NULL THEN
        RETURN 'not_configured';
    END IF;

    -- Compara digests e não os textos: o tempo da comparação não depende do
    -- prefixo em comum com o segredo.
    IF p_secret IS NOT NULL
       AND sha256(convert_to(p_secret, 'UTF8')) = sha256(convert_to(v_expected, 'UTF8')) THEN
        RETURN 'ok';
    END IF;

    RETURN 'invalid';
END;
$$;

COMMENT ON FUNCTION public.cron_deadlines_secret_status(text) IS
'ADR-0024: valida o header x-cron-secret da Edge check-opportunity-deadlines contra o Vault (cron_check_deadlines_secret). Devolve ok | invalid | not_configured; nunca o segredo. Só service_role.';

-- 3. Disparo do cron ----------------------------------------------------------
-- O tipo de retorno muda (void -> bigint), o que CREATE OR REPLACE não faz.
-- Há uma única assinatura; o job referencia a função pelo texto do comando.
DROP FUNCTION IF EXISTS public.cron_check_deadlines();

CREATE FUNCTION public.cron_check_deadlines()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_url     text;
    v_secret  text;
    v_net_id  bigint;
    v_missing text[] := ARRAY[]::text[];
BEGIN
    SELECT nullif(trim(ds.decrypted_secret), '')
      INTO v_url
      FROM vault.decrypted_secrets ds
     WHERE ds.name = 'cron_check_deadlines_url';

    SELECT nullif(trim(ds.decrypted_secret), '')
      INTO v_secret
      FROM vault.decrypted_secrets ds
     WHERE ds.name = 'cron_check_deadlines_secret';

    IF v_url IS NULL THEN
        v_missing := array_append(v_missing, 'cron_check_deadlines_url');
    END IF;

    IF v_secret IS NULL THEN
        v_missing := array_append(v_missing, 'cron_check_deadlines_secret');
    END IF;

    IF array_length(v_missing, 1) > 0 THEN
        RAISE EXCEPTION
            'cron_check_deadlines: segredo(s) ausente(s) no Supabase Vault (%). Nenhum admin_alert será gerado. Provisione fora do Git com SELECT vault.create_secret(<valor>, <nome>); o valor do segredo vem do Snaps project_config (NUBO_CRON_DEADLINES_SECRET).',
            array_to_string(v_missing, ', ')
            USING ERRCODE = 'configuration_limit_exceeded';
    END IF;

    v_url := rtrim(v_url, '/');
    IF v_url !~ '^https://[a-z0-9-]+\.supabase\.co$' THEN
        RAISE EXCEPTION
            'cron_check_deadlines: cron_check_deadlines_url no Vault não é uma URL de projeto Supabase (https://<ref>.supabase.co)'
            USING ERRCODE = 'configuration_limit_exceeded';
    END IF;

    SELECT net.http_post(
        url := v_url || '/functions/v1/check-opportunity-deadlines',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', v_secret
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
    ) INTO v_net_id;

    IF v_net_id IS NULL THEN
        RAISE EXCEPTION
            'cron_check_deadlines: net.http_post não devolveu request id — a chamada não foi enfileirada';
    END IF;

    -- net.http_post é assíncrono: enfileirar não é ter respondido. Conferir
    -- net._http_response WHERE id = <request id> (status_code e content).
    RAISE NOTICE 'cron_check_deadlines: requisição % enfileirada para %', v_net_id, v_url;
    RETURN v_net_id;
END;
$$;

COMMENT ON FUNCTION public.cron_check_deadlines() IS
'Dispara a Edge Function check-opportunity-deadlines (ADR-0024) com o header x-cron-secret e devolve o request id do pg_net. URL e segredo vêm do Vault (cron_check_deadlines_url, cron_check_deadlines_secret); ausência é erro explícito. Agendada pelo job check-program-deadlines, 0 8 * * * (GMT).';

-- 4. ACL ----------------------------------------------------------------------
DO $acl$
DECLARE
  v_fn   text;
  v_role text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'public.cron_check_deadlines()',
    'public.cron_deadlines_secret_status(text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_fn);
    FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'partner'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', v_fn, v_role);
      END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', v_fn);
    END IF;
  END LOOP;
END
$acl$;
