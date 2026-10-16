# Integração da Sprint 9.0 no DEV

`run_dev.sh` roda tudo numa única transação no DEV (`yfgciamhzjvarwgzosto`), e ela
sempre termina em exceção, então nada persiste. O resultado aparece na mensagem:
`S9_ALL_PASS` ou `S9_FAIL`.

```bash
bash supabase/tests/sprint9_integration/run_dev.sh plan   # lista o que falta no histórico do DEV
bash supabase/tests/sprint9_integration/run_dev.sh red    # sem 20261016135100/135200: deve falhar
RED_SKIP=20261016135200 bash supabase/tests/sprint9_integration/run_dev.sh red   # só sem o guard
bash supabase/tests/sprint9_integration/run_dev.sh        # GREEN
```

O que a suíte faz:

1. **Aplica as pendentes.** Pendente é todo arquivo de `supabase/migrations` cuja
   versão não está em `supabase_migrations.schema_migrations` do DEV. Elas são
   aplicadas em ordem de versão.
2. **Reaplica e compara.** Reaplica as migrations da sprint que o DEV já tem
   (#57: 193000/194500/195500; #64: 202041) e compara as definições, ignorando CRLF.
   Se forem idênticas, o DEV está rodando o que está no Git.
3. **Testa o contrato** com fixtures de quatro papéis (comum, `Controle de usuários`,
   `Parceiros`, membro de `partners_users`) e `anon`:
   - `user_profiles.phone`: `text`, nullable, sem default, igual a produção, sem dado preenchido;
   - nenhuma RPC da entrega executável por `anon`, e as RPCs de filtros sem overload;
   - `get_admin_funnel_users`: só backoffice, `Parceiros` ou service_role;
   - `get_partner_applications_by_institution`: o portal vê só a própria instituição;
     a consulta sem instituição (`NULL`) é só para admin;
   - o funil e os redirects do portal (TP-2) continuam acessíveis ao parceiro.

Para recusar outro alvo, a suíte exige `cron.job = 1`, o que vale só no DEV
(PROD tem 2 jobs). Migrations com `BEGIN;`/`COMMIT;` no topo do arquivo têm só
essas linhas removidas. O bundle é abortado se ainda contiver controle de transação.

## Massa de QA do assurance (`qa_seed.sh`)

Ao contrário do `run_dev.sh`, este script **persiste** dados no DEV, porque o
assurance humano precisa vê-los na tela. Cada execução apaga a rodada anterior e
recria tudo com datas relativas a `now()`. Para remover ao fim do assurance:
`bash supabase/tests/sprint9_integration/qa_seed.sh cleanup`.

Tudo o que o seed cria é identificável e só isso é removido:
- UUIDs `5e9a0000-…`;
- nomes `[QA-S9]`;
- e-mails `@qa-s9.invalid`;
- anônimos `qa-s9-anon-*`.

O seed reaproveita os parceiros que já existem no DEV: "[QA SEED] Bolsa Integral QA-7" e "BIP Impulsiona".

| Aluno | First-touch (last-touch) | Mensagens (sessões) | Match | Renda |
|---|---|---|---|---|
| 01 Ana | L1 = Campanha A + Divulgador X (last: L3) | 6 (3) | v1 MEC | R$ 450 |
| 02 Bruna | L1 | 4 (2) | v0 resultado | R$ 900 |
| 03 Caio | L1 | 2 (1), favorito | v1 só parceiro | R$ 1.200 |
| 04 Davi | L1 | 2 (1) + chat match_workflow | tentou v0 | R$ 2.500 |
| 05 Elisa | L2 = Campanha A + Divulgador Y | 2 (1) | v1 erro | faixa SM (candidatura) |
| 06 Felipe | L2 | 2 (1) | nunca | não respondeu |
| 07 Gabi | L3 = Campanha B + Divulgador X | 4 (2) | v1 MEC | R$ 4.000 |
| 08 Heitor | L3 | 2 (1) | nunca | R$ 700 |
| 09 Iara | sem atribuição | — (preferência e favorito no período) | v0 resultado | R$ 300 |
| 10 João | sem atribuição | — (favorito no período) | v1 pronto sem resultado | R$ 3.500 |
| 11 Kátia | sem atribuição | — | nunca | não respondeu |
| 12 Lucas | sem atribuição | — (sem preferências) | nunca | não respondeu |

Outros dados criados:
- **Cliques em card:** 01, 02 e 03 → QA-7; 07 e 09 → BIP; mais dois cliques anônimos → QA-7.
- **Candidaturas:** 01 (QA-7, enviada), 05 (QA-7, iniciada), 07 (QA-7, enviada), 02 (BIP, enviada), 09 (BIP, iniciada).
- **Fixture do cron:** `important_dates` `5e9a0000-…b001`, com início em now()+2 dias.
