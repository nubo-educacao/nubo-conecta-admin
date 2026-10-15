# E2E e monitoramento — `cron_check_deadlines` (ADR-0024, NUB-RD-75c)

O pg_cron registrar `succeeded` não prova nada: o job já ficou verde por meses
sem gerar um alerta sequer. O aceite é a cadeia inteira:
**request id → HTTP 200 da Edge → `admin_alerts` pending → repetição sem duplicata.**

## Configuração (fora do Git)

| Onde | Nome | Conteúdo |
|---|---|---|
| Snaps project_config (kind=secret, por environment) | `NUBO_CRON_DEADLINES_SECRET` | fonte da verdade do segredo |
| Supabase Vault | `cron_check_deadlines_secret` | cópia do valor acima |
| Supabase Vault | `cron_check_deadlines_url` | `https://<ref>.supabase.co` |

```sql
SELECT vault.create_secret('<valor do Snaps>', 'cron_check_deadlines_secret');
SELECT vault.create_secret('https://<ref>.supabase.co', 'cron_check_deadlines_url');
-- rotação: SELECT vault.update_secret(id, '<novo valor>') FROM vault.secrets WHERE name = '...';
```

A Edge é publicada com `verify_jwt = false` (ver `supabase/config.toml`) e
autentica pelo header `x-cron-secret`, comparado ao Vault pela RPC
`cron_deadlines_secret_status` (só `service_role`).

## Roteiro E2E (staging)

```sql
-- 1. fixture identificada (start em +2 dias cai na janela mec_period_start)
INSERT INTO public.important_dates (title, description, start_date, type, controls_opportunity_dates)
VALUES ('[QA-75c] fixture cron ADR-0024', 'remover após E2E', now() + interval '2 days', 'general', true)
RETURNING id;

-- 2. disparo: devolve o request id do pg_net
SELECT public.cron_check_deadlines();

-- 3. resposta da Edge (net._http_response expira em ~6h)
SELECT id, status_code, content FROM net._http_response WHERE id = <request id>;
-- esperado: 200 e alerts_inserted = 1

-- 4. alerta real
SELECT alert_type, status FROM public.admin_alerts WHERE entity_id = '<fixture id>';
-- esperado: mec_period_start / pending

-- 5. repetir 2 e 3: alerts_inserted = 0, alerts_deduplicated = 1, um único pending

-- 6. cleanup
DELETE FROM public.admin_alerts WHERE entity_id = '<fixture id>';
DELETE FROM public.important_dates WHERE id = '<fixture id>' AND title LIKE '[QA-75c]%';
```

Negativos esperados: sem header → 401; header errado → 401; Vault sem o
segredo → 503; `cron_check_deadlines()` sem Vault → erro 53400 nomeando o que
falta; insert pending duplicado → 23505 em `admin_alerts_pending_dedupe_uidx`.

## Monitoramento diário

```sql
SELECT d.start_time, d.status, d.return_message
  FROM cron.job_run_details d
  JOIN cron.job j USING (jobid)
 WHERE j.jobname = 'check-program-deadlines'
 ORDER BY d.start_time DESC LIMIT 7;

-- resposta da Edge do mesmo dia (antes de expirar)
SELECT id, status_code, content, created
  FROM net._http_response
 WHERE created > now() - interval '6 hours'
 ORDER BY created DESC;
```

`failed` no job = configuração ausente ou URL inválida. `succeeded` com
status_code ≠ 200 = falha na Edge (401 segredo divergente entre Snaps/Vault,
503 Vault sem segredo, 500 erro de leitura/insert).

## Rollback

`SELECT cron.alter_job(<jobid>, active := false);` — ou remover o segredo do
Vault, que faz o job voltar a falhar explicitamente.
