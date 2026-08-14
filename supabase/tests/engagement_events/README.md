# Teste de `engagement_events`

Exercita a migration `20260812130000` contra um Postgres real: backfill,
reconciliação, idempotência, as 5 CHECK constraints, a RPC e o RLS.

## O fixture reproduz a forma dos dados de produção

Não são números aleatórios. O ponto é reproduzir o caso que decidiu o desenho:
usuários que aparecem **nas duas** tabelas de origem (em prod são 119 pares).

| usuário | `partners_click` | `external_redirect_clicks` |
|---|---|---|
| u1 | 3 cliques (1 linha) | 2 eventos |
| u2 | 1 clique  (1 linha) | 1 evento  |
| u3 | 5 cliques (1 linha) | —         |
| u4 | —                   | 1 evento  |

Origem: 9 cliques de card em 3 linhas agregadas, 4 redirects.
Esperado em `engagement_events`: 3 linhas `card_click` somando `event_count` 9,
e 4 linhas `redirect` somando 4.

É esse par (3 linhas / 9 eventos) que prova a diferença entre `COUNT(*)` e
`SUM(event_count)` — usar o primeiro perde 6 cliques históricos.

## Rodar

```bash
docker run -d --name nubo-ee-test \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=nubotest -p 55443:5432 postgres:15-alpine
# criar roles anon/authenticated/partner, schema auth com auth.uid(),
# is_backoffice_admin() alternável por GUC, e as tabelas de origem — ver
# o cabeçalho da migration para os DDLs exatos das tabelas legadas.
docker exec -i nubo-ee-test psql -U postgres -d nubotest -v ON_ERROR_STOP=1 \
  < supabase/migrations/20260812130000_engagement_events.sql
```

Esperado: `NOTICE: reconciliação OK — 4 redirects, 9 cliques de card`.

A migration **falha de propósito** se o backfill não reconciliar. Um backfill
que perde ou duplica linha em silêncio é pior que um que não roda: a métrica
fica errada e ninguém percebe.

## Verificações que valem repetir depois de qualquer mudança

- Rodar a migration **duas vezes**: a segunda não pode alterar contagem
  (idempotência vem do `UNIQUE (event_id)` com prefixo de origem).
- `anon` não pode ler a tabela nem executar `get_student_clicks_admin`.
- Um evento anônimo com `channel_link_id` (o caso da rota `/r/<code>`) precisa
  ser aceito — é o que destrava a atribuição pré-login do TP-7.
- Um `card_view` de oportunidade MEC precisa ser aceito. É impossível nas
  tabelas antigas, e é o motivo da ADR-0022 existir.
