-- =============================================================================
-- Correcao de user_income estagnado  (2026-08-03)
-- =============================================================================
-- ⚠️ RECUPERADA DE PRODUÇÃO EM 13/08/2026.
--    Aplicada direto em prod e nunca versionada. Extraída de
--    supabase_migrations.schema_migrations, não reescrita.
--
-- CONTEXTO
--   Follow-up de 20260803120000. Aquela migration usou semantica fill-if-null e
--   por isso nao corrigiu linhas de user_income que ja tinham valores, porem
--   DESATUALIZADOS em relacao a uma application posterior.
--
--   Auditoria das 14 divergencias app-vs-perfil isolou 2 casos de "perfil
--   estagnado" (user_income de mar/abr, application de julho). Ao inspecionar as
--   respostas cruas, apenas 1 se confirmou:
--
--   [APLICADO] Marcelo Deny Batista De Jesus (89d29875-...)
--     user_income de 2026-03-27: family_count=1, member_incomes=[1500],
--       per_capita_income=1500  -> familia de 1 pessoa.
--     application de 2026-07-17: family_count=3, member_incomes=[1000,500,1500],
--       social_benefits=300, per_capita_income=1100.
--     Corroborado por uma 2a application (2026-06-15) que declara renda familiar
--     "De 1 a 2 salarios minimos" -- coerente com o total de R$ 3.300 de julho e
--     incoerente com o perfil armazenado. O family_count=1 esta objetivamente
--     errado e infla a renda per capita, prejudicando a elegibilidade do aluno.
--
--   [NAO APLICADO] Fernando Bonifacio (160d27f6-...)
--     application de 2026-07-22 traz member_incomes=[4,300,0] -> o "4" e quase
--     certamente erro de digitacao (mesmo padrao do "2.537" de Nicoly Almeida).
--     Aplicar levaria per_capita_income de 640,33 para 101,33 com base num
--     DRAFT nao submetido e num valor implausivel, no sentido de inflar
--     artificialmente a elegibilidade. Requer confirmacao humana.
--
-- SEGURANCA
--   UPDATE com guarda no estado atual esperado: se a linha ja tiver sido
--   corrigida por outra via, o UPDATE nao afeta nenhuma linha (idempotente).
--
--   A guarda tambem torna esta migration segura em DEV, onde este usuario nao
--   existe: o UPDATE casa zero linhas e passa sem erro. Migration de correcao
--   de dado pontual precisa disso, senao trava todo ambiente que nao seja o de
--   origem.
-- =============================================================================

BEGIN;

UPDATE public.user_income
SET
  family_count      = 3,
  social_benefits   = 300,
  alimony           = 0,
  member_incomes    = '[1000, 500, 1500]'::jsonb,
  per_capita_income = 1100,
  updated_at        = now()
WHERE user_id = '89d29875-2510-4dfe-af6f-8b6dc0c9b622'
  AND family_count = 1
  AND per_capita_income = 1500;

COMMIT;
