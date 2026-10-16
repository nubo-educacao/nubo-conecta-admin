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
