-- TP-1 1A t3 / ADR-0024 — card 9132c4df, cenários 3 e 4
--
-- O Action Center está vazio há meses e o cron aparece VERDE.
--
-- Diagnóstico confirmado em produção:
--   cron.job id 2 'check-program-deadlines' está ativo e roda 0 8 * * *.
--   O job não é o problema. `cron_check_deadlines()` é:
--
--     v_supabase_url := current_setting('app.settings.supabase_url', true);
--     v_service_key  := current_setting('app.settings.service_role_key', true);
--     IF v_supabase_url IS NOT NULL AND v_service_key IS NOT NULL THEN
--         ... net.http_post(...) ...
--     END IF;
--
--   Ambos os settings estão AUSENTES em produção (verificado: current_setting
--   retorna NULL para os dois). O IF nunca entra, a função retorna void sem
--   erro, o pg_cron registra sucesso, e admin_alerts fica em 0.
--
--   Ou seja: o `IF` transformou uma falha de configuração em sucesso silencioso.
--   Um job que não faz nada e se reporta saudável é pior que um job quebrado —
--   ninguém investiga o que está verde.
--
-- Correção: a ausência de configuração passa a ser erro explícito. O pg_cron
-- registra a falha em cron.job_run_details com mensagem acionável, em vez de
-- 'succeeded'.
--
-- ⚠️ CONSEQUÊNCIA OPERACIONAL, LEIA ANTES DE APLICAR
--   Enquanto os segredos não forem provisionados, este job vai FALHAR uma vez
--   por dia às 08:00 e isso vai aparecer em cron.job_run_details. É o
--   comportamento desejado, não regressão. Para silenciar, provisione:
--
--     ALTER DATABASE postgres SET app.settings.supabase_url     = 'https://<ref>.supabase.co';
--     ALTER DATABASE postgres SET app.settings.service_role_key = '<service_role_key>';
--
--   Isso é passo de operação, FORA do Git — a service_role_key não pode ser
--   versionada. Só depois disso o cenário 3 do card (alerta chegando no Action
--   Center) pode ser validado.
--
-- O agendamento NÃO é tocado por esta migration. O job 2 já existe, está ativo
-- e com o schedule correto; recriá-lo arriscaria duplicar.

CREATE OR REPLACE FUNCTION public.cron_check_deadlines()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $$
DECLARE
    v_supabase_url TEXT;
    v_service_key  TEXT;
    v_net_id       BIGINT;
    v_missing      TEXT[] := ARRAY[]::TEXT[];
BEGIN
    -- nullif(trim(...)) para que string vazia conte como ausente: um setting
    -- provisionado com valor em branco falharia igual, mas passaria pelo
    -- IS NOT NULL da versão anterior.
    v_supabase_url := nullif(trim(coalesce(current_setting('app.settings.supabase_url', true), '')), '');
    v_service_key  := nullif(trim(coalesce(current_setting('app.settings.service_role_key', true), '')), '');

    -- array_append e não `||`: com uma string literal, `anyarray || anyelement`
    -- e `anyarray || anyarray` ficam ambíguos e o Postgres tenta interpretar o
    -- texto como literal de array ("malformed array literal").
    IF v_supabase_url IS NULL THEN
        v_missing := array_append(v_missing, 'app.settings.supabase_url');
    END IF;

    IF v_service_key IS NULL THEN
        v_missing := array_append(v_missing, 'app.settings.service_role_key');
    END IF;

    IF array_length(v_missing, 1) > 0 THEN
        RAISE EXCEPTION
            'cron_check_deadlines: configuração ausente (%). O job não tem como chamar a Edge Function e nenhum admin_alert será gerado. Provisione com ALTER DATABASE ... SET <setting> = ...',
            array_to_string(v_missing, ', ')
            USING ERRCODE = 'configuration_limit_exceeded';
    END IF;

    SELECT net.http_post(
        url := v_supabase_url || '/functions/v1/check-opportunity-deadlines',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_service_key,
            'Content-Type', 'application/json',
            'apikey', v_service_key
        ),
        body := '{}'::jsonb
    ) INTO v_net_id;

    IF v_net_id IS NULL THEN
        RAISE EXCEPTION
            'cron_check_deadlines: net.http_post não devolveu request id — a chamada não foi enfileirada';
    END IF;

    -- net.http_post é assíncrono: enfileirar não é o mesmo que ter respondido.
    -- O id vai para cron.job_run_details e permite cruzar com net._http_response
    -- para saber o que a Edge Function respondeu de fato.
    RAISE NOTICE 'cron_check_deadlines: requisição % enfileirada para %', v_net_id, v_supabase_url;
END;
$$;

COMMENT ON FUNCTION public.cron_check_deadlines() IS
'Dispara a Edge Function check-opportunity-deadlines (ADR-0024). Falha explicitamente se app.settings.supabase_url ou app.settings.service_role_key não estiverem provisionados — a versão anterior retornava sucesso vazio e mascarou o Action Center vazio por meses. Agendada em cron.job id 2, 0 8 * * *.';

DO $acl$
DECLARE
  v_role TEXT;
BEGIN
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.cron_check_deadlines() FROM PUBLIC';
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'partner'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION public.cron_check_deadlines() FROM %I', v_role);
    END IF;
  END LOOP;
  -- Quem chama é o pg_cron, rodando como owner. Nenhum role de aplicação
  -- precisa disparar isto manualmente.
END
$acl$;
