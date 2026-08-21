# Teste de `submit_partner_solicitation`

Prova, contra um Postgres real **com o RLS de produção replicado**, que a RPC
deduplica e limita volume — e que a abordagem anterior (SELECT de dedupe com a
anon key) era cega.

Replicar o RLS é o ponto do fixture. O teste de front que existia antes mockava
o retorno do banco: provava que a lógica reage certo ao que o banco devolve,
não que o banco devolve aquilo. A policy de leitura é restrita a admin, então
para um visitante anônimo o SELECT volta vazio **sempre**, e a dedupe nunca
disparava.

## Rodar

```bash
docker run -d --name nubo-ps-test \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=nubotest -p 55442:5432 postgres:15-alpine

D="docker exec -i nubo-ps-test psql -U postgres -d nubotest"
$D -v ON_ERROR_STOP=1 < supabase/tests/partner_solicitation_submit/fixture.sql
$D -v ON_ERROR_STOP=1 < supabase/migrations/20260812120000_partner_solicitation_submit_rpc.sql
$D            < supabase/tests/partner_solicitation_submit/assert.sql

# fechamento da porta pública
$D -v ON_ERROR_STOP=1 < supabase/migrations/20260812120100_partner_solicitations_close_public_insert.sql
$D -c "SET ROLE anon; INSERT INTO public.partner_solicitations
       (institution_name,contact_name,email,how_did_you_know)
       VALUES ('Bypass','X','x@y.z','-');"   # deve dar permission denied

docker rm -f nubo-ps-test
```

Esperado: `anon_enxerga=0` contra `existe_de_fato=1`; `duplicate` nos reenvios;
5 `created` seguidos de `rate_limited`; e `permission denied` no insert direto
depois da segunda migration.
