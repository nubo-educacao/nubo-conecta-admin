# Teste da demografia inferida por cota (NUB-RD-92)

Cobre a migration `20261019170042_demographics_quota_inferred.sql` (TP-B
`88f53add` rev. 2): `normalize_quota_token`, colunas de cota acrescentadas a
`vw_user_demographics_resolved` e os itens "(por cota)", `provenance.*.quota_*`
e `coverage` de `get_command_center_demographics(uuid, uuid, boolean)`.

| Camada | Onde roda | O que prova |
|---|---|---|
| `src/test/demographics-quota-sql.test.ts` | `pnpm test` (PGlite + `unaccent`, sem rede) | contrato da view/RPC, grafias D4, N3, recusa, conflito, cobertura, first-touch, ACL |
| `run_dev.sh` + `fixture.sql` + `baseline.sql` + `assert.sql` | DEV `yfgciamhzjvarwgzosto`, transação revertida | o mesmo contrato contra o schema e os papéis reais, mais o shape antigo preservado com os dados reais do DEV |

```bash
bash supabase/tests/demographics_quota/run_dev.sh       # GREEN: NUBRD92_ALL_PASS
bash supabase/tests/demographics_quota/run_dev.sh red   # sem a migration: deve falhar
```

O bundle é `BEGIN` → seed → captura da RPC vigente → migration → asserções →
`RAISE EXCEPTION 'NUBRD92_ALL_PASS …'`. Como termina sempre em exceção, nada
persiste. O script confere `cron.job = 1` (DEV) com o mesmo comando antes de
mandar o bundle, e a seed recusa ambientes com mais de 1.000 perfis.

## Seed

Sintética: UUIDs `9b920000-…`, e-mails `nub-rd-92-N@qa-s9.invalid`. Todos os
perfis têm first-touch na campanha da suíte (Q), e as asserções de valor usam
esse filtro para não depender dos dados reais. A tabela de perfis está no
cabeçalho de `fixture.sql`.

## Decisões que o teste fixa

- Autodeclaração (perfil ou formulário), inclusive "Prefiro não informar",
  bloqueia a inferência da dimensão.
- Escola pública + bolsa integral no mesmo perfil = conflito, sem inferência
  (P-B1, a confirmar no aceite).
- `coverage`: `self_declared + quota_inferred + uncovered = total_users`; a
  recusa fica em `uncovered` e aparece à parte em `coverage.race.declined`.
  `quota_unmapped` e `quota_conflict` são diagnóstico, não parcelas.
- Fora da inferência, raça/escola continuam idênticas às da RPC anterior:
  "Não respondeu" antigo = "(por cota)" + "Não respondeu" novo.
