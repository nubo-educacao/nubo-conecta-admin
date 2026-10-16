# Teste das views de Match/demografia do Command Center

Complemento TP-1 (card `f245da71`, plano `29c645bd` rev3 §7). Cobre a migration
`20261015204255_command_center_match_demographics_views.sql`.

Há duas camadas:

| Camada | Onde roda | O que prova |
|---|---|---|
| `src/test/command-center-match-demographics-sql.test.ts` | `pnpm test` (PGlite, sem rede) | contrato da RPC, precedência, faixa SM, ACL com schema mínimo |
| `run_dev.sh` + `assert.sql` | DEV `yfgciamhzjvarwgzosto`, transação revertida | a mesma migration contra o schema e os papéis reais do Supabase, cenários do §7 (87 asserções), reversão DDL |

## Rodar no DEV

Precisa estar autenticado no Supabase CLI (`npx supabase@2.121.0 login`).

```bash
bash supabase/tests/command-center-match-demographics/run_dev.sh       # GREEN
bash supabase/tests/command-center-match-demographics/run_dev.sh red   # sem a migration: deve falhar
```

O script monta um único arquivo: `BEGIN` → migration → `assert.sql` → migration
anterior (`20260811160000`) → `rollback_drop_views.sql` → `assert_rollback.sql`
→ `RAISE EXCEPTION 'TP1C_ALL_PASS …'`. Como termina sempre em exceção, nada
persiste: nem fixtures, nem views, nem a RPC nova. `assert.sql` recusa rodar
com mais de 1.000 perfis (PROD).

Para provar a não-persistência, rode `fingerprint.sql` (somente leitura) antes
e depois e compare: contagens e hashes das tabelas-fonte, de `auth.users`, dos
objetos e da RPC devem ser idênticos.

## Fixtures

Sintéticas, UUIDs `7c1c0000-…`. Perfis 1–12 cobrem Match (só v0 resultado, só
conversa v0, só v1 MEC, só parceiro sem preferências, erro com/sem resultado
anterior, v0+v1, nunca, órfão de preferências, dependente, `last_course_ids`
inválido/vazio). Perfis 33–48 cobrem demografia (perfil × formulário, DRAFT,
dois formulários divergentes, resposta por `partner_forms.id`, "Prefiro não
informar", renda JSON/SM/exata, cotas sem declaração, rótulo normalizado,
`education_year`, isolamento entre parceiros, valores inválidos, renda do
onboarding v0, `answers` não-objeto); 49 é candidatura órfã.

## Reversão em ambiente real

A migration não escreve dados, então reverter é só DDL:

1. aplicar de novo `supabase/migrations/20260811160000_command_center_health_demographics.sql`;
2. rodar `rollback_drop_views.sql`.

`assert_rollback.sql` confere que a RPC volta ao hash normalizado
`19a44c39cb46a62045ec0fa8edac22e1` (o de PROD e DEV em 15/10/2026).

## Depois de 20261016140000

A `20261016140000_command_center_attribution_filters` troca a assinatura de
`get_command_center_demographics()` por `(uuid, uuid, boolean)`, com os três
parâmetros DEFAULT NULL. Este bundle reaplica a `20261015204255`, que faz
`CREATE OR REPLACE` da versão sem argumentos e, por isso, deixa duas assinaturas
na transação (42725). Num banco que já tem a `140000`, ele não roda mais.

Ele deu 87/87 no DEV em 2026-10-16, depois da aplicação da `204255` e antes da
`140000`. A partir da `140000`, use `supabase/tests/command_center_attribution_filters`:
ela confere o baseline sem filtro, a soma das dimensões igual a `match_health.total`
e o ACL na assinatura nova.
