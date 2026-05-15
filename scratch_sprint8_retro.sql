-- =============================================================================
-- Sprint 8.0 — Trouble Report + Retrospectiva
-- Projeto: d5142c4c-efaf-4af8-9399-0cd9864963f7
-- Execution ID: f22bb93e-33e0-4b68-b449-55b1a15ffeba
-- =============================================================================

-- Buscar o sprint_id da Sprint 8.0 dinamicamente
-- (ajuste o filtro de name/tag se necessário)
DO $$
DECLARE
  v_sprint_id UUID;
  v_project_id UUID := 'd5142c4c-efaf-4af8-9399-0cd9864963f7';
  v_execution_id UUID := 'f22bb93e-33e0-4b68-b449-55b1a15ffeba';
BEGIN

  SELECT id INTO v_sprint_id
  FROM sprints
  WHERE project_id = v_project_id
    AND (name ILIKE '%sprint 8%' OR tag ILIKE '%sprint-8%')
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_sprint_id IS NULL THEN
    RAISE EXCEPTION 'Sprint 8.0 não encontrada no banco. Verifique o nome/tag.';
  END IF;

  RAISE NOTICE 'Sprint 8.0 encontrada: %', v_sprint_id;

  -- -------------------------------------------------------------------------
  -- 1. TROUBLE REPORT (test_plans)
  -- -------------------------------------------------------------------------
  INSERT INTO test_plans (
    id,
    project_id,
    sprint_id,
    title,
    status,
    content,
    execution_log
  ) VALUES (
    gen_random_uuid(),
    v_project_id,
    v_sprint_id,
    'Trouble Report: Sprint 8.0',
    'failed',
    $CONTENT$
# Trouble Report: Sprint 8.0

## Resultado do QA: FAILED

## Bugs Críticos

### BUG-TC15 — RPC `submit_application_v1` retorna 404
- **Sintoma:** Ao clicar em "Enviar Candidatura" no último step do formulário de candidatura parceira, ocorre `404 Not Found` em `POST /rpc/submit_application_v1`
- **Causa Raiz:** A RPC não existe no banco. O card de polimento do formulário focou no layout/UX mas não incluiu a criação da função de backend como entregável explícito.
- **Severidade:** 🔴 Bloqueante — impede completar qualquer candidatura
- **Destino:** Sprint 11, Card 9.4.1

### BUG-TC16 — Seletor de Perfil/Dependente aparece em steps além do Step 1
- **Sintoma:** O seletor "Bruno Barbosa / Dependente..." deve aparecer apenas no Step 1 (identificação). Atualmente aparece em outros steps também.
- **Severidade:** 🟡 Alta
- **Destino:** Sprint 11, Card 9.4.2

### BUG-TC17 — Pré-preenchimento não adapta ao trocar de perfil
- **Sintoma:** Ao trocar entre perfil principal e dependente no Step 1, os campos não são limpos e recarregados com os dados do novo perfil selecionado.
- **Severidade:** 🟡 Alta
- **Destino:** Sprint 11, Card 9.4.3

## Itens Validados com Sucesso (10/13 TCs)
- TC-01: Badge de ciclo dinâmico (SiSU 2026 / ProUni 2025.1) ✅
- TC-02: Deduplicação de modalidades por ciclo ✅
- TC-03: Fallback de nota de corte de ciclo anterior ✅
- TC-08/09: Card "Sua Nota para este Curso" (SiSU e ProUni) ✅
- TC-10: Seletor de anos ENEM no onboarding mostra 2025/2024/2023 ✅
- TC-12: Carrossel de oportunidades por match_score ✅ (requer match regenerado)
- Domínio de Instituições: 19/19 testes passando ✅
- ProfileContext + Dropdown TopBar ✅
- Favoritos com remoção otimista ✅
- ApplicationStepper visual ✅
$CONTENT$,
    jsonb_build_object(
      'execution_id', v_execution_id::text,
      'agent', '@antigravity-retro-analyst',
      'bugs_count', 3,
      'tcs_passed', 10,
      'tcs_total', 13,
      'cards_done', 13,
      'cards_total', 13
    )
  );

  RAISE NOTICE 'Trouble Report inserido com sucesso.';

  -- -------------------------------------------------------------------------
  -- 2. WALKTHROUGH — RETROSPECTIVA (snaps)
  -- -------------------------------------------------------------------------
  INSERT INTO snaps (
    id,
    project_id,
    sprint_id,
    agent_execution_id,
    name,
    description,
    content,
    status,
    snadds
  ) VALUES (
    gen_random_uuid(),
    v_project_id,
    v_sprint_id,
    v_execution_id,
    'Retrospectiva: Sprint 8.0 — Dependentes, Favoritos e Workflow Misto',
    'Análise completa de entrega, bugs, débito técnico e recomendações para Sprint 11.',
    $RETRO$
# 🏆 Retrospectiva — Sprint 8.0
**Dependentes, Favoritos e Workflow Misto**

## 📊 Velocity & Métricas

| Métrica | Valor |
|---------|-------|
| Cards planejados | 13 |
| Cards entregues (DONE) | 13 |
| Completion rate | 100% |
| QA Final | ❌ Failed (3 bugs) |
| TCs passados | 10/13 |
| Walkthroughs gerados | 8 |

## ✅ O que foi bem

### 1. Fundação Multi-Perfil Sólida
`ProfileContext` entregue como Plano A, propagado corretamente para chatService, FavoritesContext, DadosTab e ApplicationStepper. Persistência em localStorage funcionando.

### 2. Arquitetura DB-First Respeitada
DDL antes de interfaces, consumo via `v_unified_opportunities`, Edge Functions no padrão existente. Zero violações de ADR.

### 3. Peer Reviewer Eficaz
`@antigravity-peer-reviewer` detectou o path incorreto `(app)/new-application` vs `(protected)/new-application` e a ausência de `getRelatedOpportunities` antes do executor começar.

### 4. Domínio de Instituições com Qualidade
InstitutionCard, /instituicoes e /instituicoes/[id] entregues com 19/19 testes. Bug de filtro por `provider_name` corrigido para `.eq('institution_id', id)`.

### 5. Pipeline de Normalização Estruturado
Tabelas `opportunitiessisuapprovals` e `opportunities_prouni_vacancies` criadas com estratégia de ciclos semestrais.

## ❌ O que deu errado

### 1. RPC `submit_application_v1` nunca foi criada (BUG-TC15)
O card de polimento do formulário focou em layout/UX mas não especificou a criação da função de backend como entregável. O peer reviewer não auditou `pg_proc` para validar existência da RPC.

### 2. Estado do Formulário Vaza Entre Steps e Perfis (TC16 + TC17)
O plano não especificou isolamento de estado por step e por profileId como critério de aceite explícito. Cada profileId deve ter seu próprio slice de estado.

### 3. `rawprouniocuppied2025` Efetivamente Vazia
2 rows com NULLs. Métricas de "Vagas Ociosas" do ProUni ficam zeradas. Limitação não comunicada explicitamente.

## 🔧 Débito Técnico

| Item | Destino |
|------|---------|
| ETL ProUni year-agnostic | Sprint 11 Card 9.1.2 |
| RPC submit_application_v1 ausente | Sprint 11 Card 9.4.1 |
| Estado do formulário vaza entre perfis | Sprint 11 Cards 9.4.2/9.4.3 |

## 📐 Melhorias de Processo

1. **Critério de Aceite para RPCs:** Todo card de submissão DEVE listar "RPC X existe no banco com assinatura validada". Peer reviewer deve verificar `pg_proc`.
2. **Isolamento de Estado por Step:** Formulários multi-step com seleção de perfil DEVEM especificar `{ [profileId]: FormState }`.
3. **Comunicação de Limitações de Dados:** Quando ETL depende de tabela raw vazia, incluir nota de limitação visível ao usuário.

## 🚀 Recomendações para Sprint 11

- Wave 1: BUG-TC15, TC16, TC17 + ETL ProUni type mismatch (desbloqueiam candidaturas)
- Wave 2: Programs Object (SiSU/ProUni como entidade gerenciável)
- Wave 3: Action Center + botão Candidatar dinâmico
$RETRO$,
    'completed',
    jsonb_build_object(
      'type', 'walkthrough',
      'subtype', 'retrospective',
      'sprint', 'Sprint 8.0',
      'agent', '@antigravity-retro-analyst'
    )
  );

  RAISE NOTICE 'Walkthrough de retrospectiva inserido com sucesso.';

END $$;
