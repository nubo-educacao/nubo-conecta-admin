# Command Center — paridade e desempenho do recorte em SQL (NUB-RD-93)

As Edges `analytics-stats`, `analytics-activity` e `analytics-rankings` passaram a
fazer uma única chamada às RPCs `cc_*_aggregate`
(`supabase/migrations/20261019171331_cc_attribution_sql_aggregates.sql`), em vez de
paginar `user_attribution`, `channel_links`, `user_profiles`, `user_favorites`,
`user_preferences` e `chat_messages` e recortar em memória.

| Script | O que faz | Escreve? |
|---|---|---|
| `differential.mjs` | Roda a Edge **anterior** (lida do Git em `4cb20f1b`, sobre um PostgREST simulado) e a **atual** (RPC num Postgres embutido com a migration real) sobre os mesmos dados. Compara status e corpo byte a byte em 442 células: 3 Edges × 6 recortes × 5 períodos × modos/fusos/zoom, além das entradas inválidas. | Não |
| `dump_dev.sh` | Dump das 6 tabelas lidas, a partir do DEV, para alimentar o diferencial com dados reais. Recusa outro alvo (`cron.job = 1`). O arquivo tem nomes e cidades: grave **fora** do repositório. | Não (só lê o DEV) |
| `prod_explain.mjs` | Gera um bloco `DO` que roda `EXPLAIN (ANALYZE, BUFFERS)` N+1 vezes por célula e termina em `RAISE EXCEPTION 'CC_PERF {json}'`. Compara os SELECTs da Edge anterior com o corpo das RPCs, com os parâmetros como literais. Não cria objetos. | Não |

```bash
node supabase/tests/cc_perf/differential.mjs                       # sintético, semente 93
node supabase/tests/cc_perf/differential.mjs --seed 42 --users 2000
bash supabase/tests/cc_perf/dump_dev.sh /tmp/fora-do-repo/dev.json && node supabase/tests/cc_perf/differential.mjs --data /tmp/fora-do-repo/dev.json
node supabase/tests/cc_perf/prod_explain.mjs --edge stats --campaign <uuid> --channel <uuid> --n 5 --to 2026-10-19T17:00:00Z
```

O oráculo detecta regressões. Cada uma destas mutações da migration faz o
diferencial falhar: sessão com `>=` em vez de `>`, last-touch no lugar de
first-touch, último dia sem o `- 1 ms`, ordem de primeira aparência invertida e
"sem atribuição" vazio.

## Resultados de 19/10/2026

### Paridade (diferencial, 442 células cada)

| Massa | Resultado |
|---|---|
| Sintética, sementes 1 a 5 e 93 (≈200–300 usuários) | `DIFF_ALL_PASS` |
| Sintética, semente 42 (1.709 perfis, 12.343 mensagens) | `DIFF_ALL_PASS` |
| DEV real (49 perfis, 1.226 mensagens, seed QA-S9) | `DIFF_ALL_PASS` |

### Tempo de SQL em PROD (só leitura)

Medição pelo conector read-only em 19/10/2026, janela de 7 dias
`[2026-10-12T17Z, 2026-10-19T17Z)` (stats: anterior desde `2026-10-05T17Z`), activity no modo `week`
e rankings no tipo `users`.

Células:
- campanha **SISU+**: 1 link e 0 pessoas por first-touch, o caso do relato;
- divulgador "Disparo Ponte e Sol 09/03": 191 first-touch;
- sem atribuição: 4.227 perfis;
- sem filtro.

Medições: 1 execução fria e 5 aquecidas, espaçadas em 200 ms. A tabela mostra a mediana e o máximo das aquecidas, em ms (planejamento + execução).

- **Antes** é um limite inferior: a soma dos SELECTs que a Edge mandava, sem
  paginação. A Edge real fazia uma ida HTTP por página de 1.000 linhas
  (coluna *idas*), e cada ida soma rede, PostgREST e serialização.
- **Depois** é o corpo da RPC com os parâmetros como literais (a função não existe em PROD).

Estes números **não** são p95 de Edge. Não comparar com latência ponta a ponta.

| Edge | Recorte | Antes: mediana / máx (fria) | Depois: mediana / máx (fria) | Idas ao banco |
|---|---|---|---|---|
| stats | campanha SISU+ | 14,59 / 14,80 (20,70) | 4,84 / 5,38 (5,65) | 11 → 1 |
| stats | divulgador | 14,77 / 16,98 (14,38) | 5,84 / 6,57 (30,76) | 11 → 1 |
| stats | sem atribuição | 21,74 / 23,67 (21,87) | 14,28 / 16,31 (14,50) | 16 → 1 |
| stats | sem filtro | 17,84 / 24,35 (17,61) | 4,65 / 4,94 (4,63) | 11 → 1 (+ Auth) |
| activity | campanha SISU+ | 4,02 / 4,40 (3,93) | 3,09 / 3,40 (7,33) | 3 → 1 |
| activity | divulgador | 3,94 / 4,00 (3,92) | 3,28 / 3,31 (3,26) | 3 → 1 |
| activity | sem atribuição | 10,71 / 10,81 (10,23) | 9,46 / 9,71 (9,06) | 8 → 1 |
| activity | sem filtro | 2,24 / 2,28 (2,23) | 2,89 / 2,96 (2,86) | 1 → 1 |
| rankings | campanha SISU+ | 12,95 / 13,46 (407,48) | 2,89 / 3,02 (3,07) | 10 → 1 |
| rankings | divulgador | 13,02 / 13,43 (12,97) | 3,23 / 3,44 (7,58) | 10 → 1 |
| rankings | sem atribuição | 19,25 / 20,64 (19,77) | 9,04 / 9,38 (15,91) | 15 → 1 |
| rankings | sem filtro | 11,67 / 13,80 (11,36) | 3,00 / 3,80 (6,84) | 8 → 1 |

Leitura dos números:
- O ganho grande é o fim das idas paginadas: de 3 a 16 viram 1.
- Em SQL puro, o "depois" é menor ou igual em 11 das 12 células.
- Em `activity` sem filtro, o "depois" fica ≈0,6 ms mais lento, mas com o mesmo número de idas: os buckets por fuso, antes em JS, agora rodam no banco.
- A execução fria de rankings/SISU+ antes (407 ms, 275 blocos lidos do disco) mostra o custo de ler `user_profiles` inteiro sem cache. O "antes" também conta perfis e favoritos nessa célula, que a Edge pulava quando a campanha não tinha mensagens; é um limite superior só nesse ponto.
- O "depois" de stats/sem atribuição já usa a versão final da contagem de cadastros. A primeira versão fazia 4.227 sondagens de índice: 24 ms e 15.919 buffers. As outras células de stats foram medidas com essa primeira versão, que só difere na contagem de cadastros do recorte; nelas o conjunto tem 0 ou 191 pessoas.

### p95 ponta a ponta no DEV

**Não medido nesta execução.** Exige invocar as Edges no DEV com um token de usuário
backoffice, e a criação/uso de credencial foi bloqueada no ambiente do agente. Além disso,
as Edges novas não podem ser publicadas no DEV antes da migration, e o `db push` no DEV
está bloqueado pela divergência `20261015140000_conversion_event_claims` (O1).
