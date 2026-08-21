# Teste do modelo de canal

Exercita `20260812140000_channel_model.sql` com os **82 codes reais de
produção** semeados — não com dados inventados. É o que faz o teste valer:
metade dos achados abaixo só aparece com os dados de verdade.

## O que o teste precisa provar

**Classificação exata dos 82.** Esperado, conforme validado com marketing
(§3.1.1 do governance doc `f74d1cd9`):

| medium | canais | arquivados |
|---|---|---|
| influencer | 30 | 0 |
| owned | 26 | 22 |
| partner | 11 | 0 |
| crm | 10 | 0 |
| paid | 3 | 0 |
| event | 2 | 0 |

Os 22 arquivados são os códigos `*INT` — unidades da USP (EACH, ECA, FAU, FEA,
FFLCH, Poli…), de uma ação que não usa mais este mecanismo. **Arquivar, nunca
deletar**: se algum link ainda circular, o clique precisa continuar resolvendo.

**Campanhas retroativas.** Bolsa Insper 2026 deve reagrupar **10 links** — a
campanha que hoje existe espalhada e que ninguém consegue somar.

**Códigos legados preservados literalmente.** `fundação1Bi`, `insper21/07`,
`sisu+`, `disparo24/03` e `paloma-BA` precisam sobreviver ao backfill sem
reescrita. Um code alterado é um link distribuído que deixa de atribuir.

> Foi aqui que o teste pegou um bug real: o `CHECK` original do `code` era uma
> allowlist `[A-Za-z0-9._/+-]` e rejeitava `fundação1Bi`. A constraint estava
> errada sobre a realidade, não o dado. Virou regra negativa — barra espaço e
> os metacaracteres de query/fragmento, aceita o resto.

**Integridade do acoplamento com o TP-2.** Depois desta migration,
`engagement_events.channel_link_id` ganha FK. Um evento apontando link
inexistente deve ser rejeitado; um evento anônimo em link real deve passar —
é o caso da rota `/r/<code>`, que ocorre antes do login.

## Rodar

Semear as tabelas legadas (`influencers` com os 82 codes, `user_profiles` com
`referral_source`), aplicar `20260812130000_engagement_events.sql` e depois
esta. Esperado no log:

```
NOTICE: canal OK — 82 legados -> 82 canais / 82 links; atribuição: N de N perfis com referral
```

A migration **falha** se os números não baterem.
