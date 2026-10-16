# Teste dos filtros de campanha/divulgador (first-touch)

TP-7 / NHB-123b. Exercita contra um Postgres real a migration
`20261015202330_tp7_first_touch_attribution_filters.sql`, que acrescenta
`p_filter_campaign_id`, `p_filter_channel_id` e `p_filter_unattributed` a
`get_students_paginated`, `get_student_stats` e
`get_student_applications_with_details`.

## Rodar

```bash
bash supabase/tests/attribution_filters/run-dev.sh          # com a migration (GREEN)
bash supabase/tests/attribution_filters/run-dev.sh --red    # sem a migration (RED)
```

Precisa do Supabase CLI autenticado. O script liga o CLI ao **DEV**
(`yfgciamhzjvarwgzosto`), confere o ref antes de executar e faz `unlink` no fim.

Tudo roda numa única transação: fixtures → captura do baseline com as funções
**antigas** → migration → asserções. O último bloco **sempre** lança exceção:

- `TP7_ALL_PASS (N verificações; transação desfeita)` — sucesso;
- `TP7_FAIL (k/N falharam): [...]` — lista esperado/obtido de cada falha.

Nos dois casos nada fica no banco, nem a migration nem as fixtures. Por isso o
CLI mostra `unexpected status 400` mesmo no sucesso; leia a mensagem.

## O que é verificado

1. **Filtro nulo preserva o baseline**: páginas em várias ordenações, contagem,
   stats e inscrições, com os dados reais do ambiente, idênticos antes e depois.
2. **First-touch**: U2 chegou por um link da campanha A e voltou por um da B;
   conta só em A.
3. Campanha, divulgador, campanha + divulgador, combinação sem link (vazio,
   count 0), "sem atribuição" (sem linha ou com `first_touch_link_id` nulo).
4. Contagem e paginação coerentes e sem pessoas duplicadas.
5. Total de `get_student_stats` = `count` da lista para o mesmo recorte,
   inclusive com renda vinda só de `user_income`.
6. Inscrições recortadas pelo first-touch do aluno (uma linha por inscrição).
7. `22023` para "sem atribuição" + campanha/divulgador; `42501` para quem não é
   backoffice; `anon` sem EXECUTE; uma única assinatura por função.

Para conferir que o teste pega regressões: troque `first_touch_link_id` por
`last_touch_link_id` no JOIN de `matches_first_touch_attribution` — 7
verificações falham.

## Drift conhecido do DEV

Em 15/10/2026, PROD tem `user_profiles.phone` e o DEV não; a
`get_students_paginated` atual já falha no DEV com `42703`. O `fixture.sql`
adiciona a coluna dentro da transação para espelhar PROD. Não é correção do DEV.
