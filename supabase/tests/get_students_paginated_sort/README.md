# Teste de ordenação de `get_students_paginated`

Prova, contra um Postgres real, que a RPC ordena pelo campo pedido. É o único
teste que exercita o SQL — os testes de vitest cobrem só o contrato do front.

Existe porque o bug do card `1a658f84` era invisível para qualquer teste de
front: a RPC **aceitava** `p_sort_by`, não dava erro, e devolvia os dados na
ordem errada.

## Rodar

Não precisa de Supabase local nem de acesso a produção — só Docker.

```bash
docker run -d --name nubo-sort-test \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=nubotest \
  -p 55439:5432 postgres:15-alpine

# roles que o Supabase provê e o Postgres puro não tem
docker exec -i nubo-sort-test psql -U postgres -d nubotest <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE partner NOLOGIN;
SQL

docker exec -i nubo-sort-test psql -U postgres -d nubotest -v ON_ERROR_STOP=1 \
  < supabase/tests/get_students_paginated_sort/fixture.sql

docker exec -i nubo-sort-test psql -U postgres -d nubotest -v ON_ERROR_STOP=1 \
  < supabase/migrations/20260811140000_fix_students_sort_and_harden_get_students_paginated.sql

docker exec -i nubo-sort-test psql -U postgres -d nubotest \
  < supabase/tests/get_students_paginated_sort/assert.sql

docker rm -f nubo-sort-test
```

Esperado: `PASS` nas 12 asserções.

## Como confirmar que o teste realmente pega o bug

Carregue a versão anterior da função no lugar da migration nova:

```bash
docker exec -i nubo-sort-test psql -U postgres -d nubotest \
  < supabase/migrations/20260729142530_fix_get_students_paginated_whatsapp.sql
```

Os 8 casos de ordenação passam a devolver **a mesma sequência**
(`Ana,Daniel,Beatriz,Carlos` — a ordem dos UUIDs), independentemente do
`p_sort_by`. É o sintoma exato: `DISTINCT ON (p.id)` obriga `p.id` a liderar o
`ORDER BY`, e como o id é único a coluna pedida só desempataria empates que
nunca ocorrem.

## Sobre o fixture

Os UUIDs são fixos e escolhidos de forma que a ordem por `id` não coincida com
a ordem por nenhuma outra coluna — se fossem aleatórios, o teste passaria por
acaso de vez em quando. `Beatriz` tem `age` e telefone nulos para exercitar
`NULLS LAST`, e é a única com linha em `auth.users`, cobrindo o
`COALESCE(p.phone, au.phone)` da coluna computada `whatsapp`.

`is_backoffice_admin()` é um stub alternável por GUC (`SET test.is_admin =
'off'`) para exercitar os dois lados do guard de autorização.
