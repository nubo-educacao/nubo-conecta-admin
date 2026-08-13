-- TP-2 2a — fonte de eventos agnóstica (ADR-0022) + channel_link_id (TP-7 7C)
-- Cards: eeb42964 (tracking agnóstico), 621e84b4 (dashboard B2B)
--
-- ══ O PROBLEMA ══════════════════════════════════════════════════════════════
-- Hoje existem duas tabelas de clique, ambas com partner_id NOT NULL apontando
-- para partner_opportunities. Consequência: oportunidade MEC não é rastreada de
-- jeito nenhum — `trackAndRedirect` pula o insert quando partnerId é null.
--
-- ══ O QUE A AUDITORIA DE PRODUÇÃO MOSTROU (12/08/2026) ══════════════════════
-- O TP-2 2a task 3 JÁ definia a unificação numa entidade só, com as duas
-- origens contadas SEPARADAMENTE: `source` distinto, `event_count=clicks` para
-- o agregado, `SUM(event_count)` e nunca `COUNT(*)` nas métricas históricas, e
-- relatório de reconciliação por fonte. Tudo isso vem do plano.
--
-- O que o plano deixa em aberto é qual `event_type` o `partners_click` recebe:
-- ele nomeia `redirect` para `external_redirect_clicks` e não nomeia o outro.
-- Rastreando os call sites:
--
--   partners_click          <- registerPartnerClick()
--                              chamado de MatchResults.tsx e OpportunityCard.tsx
--                              => é CLIQUE NO CARD  (card_click)
--
--   external_redirect_clicks <- trackAndRedirect()
--                              chamado do detalhe da oportunidade e do
--                              formulário de parceiro
--                              => é REDIRECT para o destino
--
-- São dois estágios do funil. Uma leitura literal do plano poderia ter posto
-- `redirect` nos dois, e aí as duas etapas colapsariam numa só.
--
-- Os 119 pares (user, partner) presentes nas duas tabelas são pessoas que
-- clicaram no card e depois foram redirecionadas — o funil funcionando.
--
-- Volumes em prod: 249 linhas agregadas somando 418 cliques de card (30/06 a
-- 12/08) e 456 eventos de redirect (14/06 a 12/08).
--
-- DESVIO DO PLANO, deliberado: o plano usa `source='legacy_aggregate'`; aqui é
-- `legacy_partners_click_aggregate`. A reconciliação exigida é POR FONTE, e um
-- nome genérico deixa de identificar a origem se outra tabela agregada for
-- migrada depois.
--
-- ⚠️ O funil histórico é NÃO-MONOTÔNICO (456 redirects > 418 card_clicks) e isso
--    não é erro de dados: dá para chegar ao detalhe da oportunidade sem passar
--    por um card de parceiro (link direto, busca, oportunidade MEC), e
--    registerPartnerClick só dispara em card de parceiro. Quem for construir o
--    dashboard do TP-2 2c precisa saber disto antes de "corrigir" o número.
--
-- ══ CONSUMIDORES A MIGRAR (levantados em prod, não presumidos) ══════════════
--   view      vw_partner_funnel          -> partners_click
--   function  get_admin_funnel_users     -> external_redirect_clicks
--   function  get_partner_redirect_users -> external_redirect_clicks
--   function  get_student_details_v2     -> external_redirect_clicks
--   app       services/partnersClickService.ts  (escrita)
--   app       services/redirectService.ts       (escrita)
--
-- Esta migration NÃO os altera. É expand/contract: cria a fonte nova e faz o
-- backfill; as tabelas antigas seguem intactas e recebendo escrita. Cortar a
-- leitura antiga é passo posterior, depois da reconciliação.

-- ── A tabela ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.engagement_events (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Idempotência. O cliente gera; reenvio de rede não vira evento novo.
  -- É também o que permite deduplicar contra o CAPI da Meta depois (TP-7 7A).
  event_id     TEXT NOT NULL,

  event_type   TEXT NOT NULL
               CHECK (event_type IN ('card_view', 'card_click', 'redirect')),

  occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Nullable de propósito: a rota /r/<code> do TP-7 acontece ANTES do login.
  -- O vínculo com a pessoa é feito depois, no stitching por anonymous_id.
  user_id      UUID,
  anonymous_id TEXT,

  -- Agnóstico: é isto que a ADR-0022 pede. Sem partner_id NOT NULL.
  entity_type  TEXT NOT NULL
               CHECK (entity_type IN ('partner_opportunity', 'mec_opportunity',
                                      'institution', 'course', 'channel_link')),
  entity_id    UUID,

  -- Snapshot textual, SEM foreign key: v_unified_opportunities é view/matview e
  -- seus ids são sintéticos ('mec_<uuid>', 'partner_<uuid>'). FK para matview
  -- não existe, e mesmo que existisse um refresh invalidaria as referências.
  unified_opportunity_id TEXT,

  -- TP-7 7C. Entra AGORA, não depois: adicionar coluna a uma tabela de eventos
  -- já populada é uma segunda migration numa tabela delicada de migrar.
  -- A foreign key para channel_links é adicionada na migration do TP-7 7B,
  -- quando a tabela existir.
  channel_link_id UUID,

  destination_url TEXT,

  -- Origem do registro. Distingue evento vivo de linha nascida em backfill —
  -- sem isso não há como reconciliar nem como excluir o legado de um recorte.
  source       TEXT NOT NULL DEFAULT 'app',

  -- 1 para evento individual; N para linha vinda de agregado legado.
  -- MÉTRICA HISTÓRICA USA SUM(event_count), NUNCA COUNT(*).
  event_count  INTEGER NOT NULL DEFAULT 1 CHECK (event_count > 0),

  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Um evento anônimo e sem sessão é um evento que não serve para nada:
  -- não dá para atribuir, nem deduplicar, nem costurar no login.
  CONSTRAINT engagement_events_has_subject
    CHECK (user_id IS NOT NULL OR anonymous_id IS NOT NULL),

  -- Redirect sem destino é registro inútil; o destino É o evento.
  CONSTRAINT engagement_events_redirect_needs_url
    CHECK (event_type <> 'redirect' OR destination_url IS NOT NULL),

  -- Engajamento com entidade do catálogo precisa dizer QUAL entidade.
  CONSTRAINT engagement_events_entity_identified
    CHECK (entity_type = 'channel_link' OR entity_id IS NOT NULL OR unified_opportunity_id IS NOT NULL),

  -- Evento de link precisa apontar o link.
  CONSTRAINT engagement_events_channel_link_identified
    CHECK (entity_type <> 'channel_link' OR channel_link_id IS NOT NULL)
);

-- Idempotência de verdade: reenvio do mesmo event_id não cria linha.
CREATE UNIQUE INDEX IF NOT EXISTS engagement_events_event_id_key
  ON public.engagement_events (event_id);

CREATE INDEX IF NOT EXISTS engagement_events_occurred_idx
  ON public.engagement_events (occurred_at DESC);

CREATE INDEX IF NOT EXISTS engagement_events_type_occurred_idx
  ON public.engagement_events (event_type, occurred_at DESC);

CREATE INDEX IF NOT EXISTS engagement_events_user_idx
  ON public.engagement_events (user_id, occurred_at DESC)
  WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS engagement_events_anon_idx
  ON public.engagement_events (anonymous_id, occurred_at DESC)
  WHERE anonymous_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS engagement_events_entity_idx
  ON public.engagement_events (entity_type, entity_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS engagement_events_channel_idx
  ON public.engagement_events (channel_link_id, occurred_at DESC)
  WHERE channel_link_id IS NOT NULL;

COMMENT ON TABLE public.engagement_events IS
'Fonte única de eventos de engajamento (ADR-0022): card_view, card_click e redirect, para parceiro e MEC. Substitui partners_click e external_redirect_clicks. Métricas históricas devem usar SUM(event_count), nunca COUNT(*) — linhas com source começando em legacy_ representam agregados. TP-2 2a.';

COMMENT ON COLUMN public.engagement_events.event_count IS
'1 em evento individual; N em linha originada de agregado legado. Sempre agregar com SUM(event_count).';

COMMENT ON COLUMN public.engagement_events.channel_link_id IS
'Link de canal que originou a visita (TP-7). FK adicionada na migration do modelo de canal.';

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- Leitura só para backoffice. Escrita autenticada só do próprio usuário.
-- Evento ANÔNIMO não entra por policy pública: entra por RPC SECURITY DEFINER
-- com idempotência e rate limit (TP-2 2a task 8). INSERT público irrestrito
-- numa tabela de eventos é um convite a envenenar métrica.
ALTER TABLE public.engagement_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS engagement_events_admin_read ON public.engagement_events;
CREATE POLICY engagement_events_admin_read
  ON public.engagement_events FOR SELECT
  USING (public.is_backoffice_admin());

DROP POLICY IF EXISTS engagement_events_self_insert ON public.engagement_events;
CREATE POLICY engagement_events_self_insert
  ON public.engagement_events FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

DO $acl$
BEGIN
  EXECUTE 'REVOKE ALL ON TABLE public.engagement_events FROM PUBLIC';
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT SELECT, INSERT ON TABLE public.engagement_events TO authenticated';
  END IF;
  -- anon NÃO recebe grant: tráfego anônimo passa pela RPC.
END
$acl$;

-- ── Backfill ────────────────────────────────────────────────────────────────
-- Sem fabricar evento. Cada linha de origem vira exatamente uma linha aqui,
-- preservando o carimbo de tempo original. event_id prefixado pela origem
-- garante idempotência: rodar a migration duas vezes não duplica.

-- external_redirect_clicks -> redirect (1 evento por linha)
INSERT INTO public.engagement_events (
  event_id, event_type, occurred_at, user_id, entity_type, entity_id,
  destination_url, source, event_count
)
SELECT
  'erc:' || e.id::text,
  'redirect',
  e.created_at,
  e.user_id,
  'partner_opportunity',
  e.partner_id,
  e.redirect_url,
  'legacy_external_redirect',
  1
FROM public.external_redirect_clicks e
ON CONFLICT (event_id) DO NOTHING;

-- partners_click -> card_click (1 linha por agregado, event_count = clicks)
--
-- created_at é o PRIMEIRO clique do par (a tabela tem UNIQUE (user_id,
-- partner_id) e incrementa um contador), então é ele que carimba o evento.
-- updated_at, o último clique, é preservado no source para não se perder — a
-- granularidade intermediária não existe e não será inventada.
INSERT INTO public.engagement_events (
  event_id, event_type, occurred_at, user_id, entity_type, entity_id,
  source, event_count
)
SELECT
  'pc:' || p.id::text,
  'card_click',
  p.created_at,
  p.user_id,
  'partner_opportunity',
  p.partner_id,
  'legacy_partners_click_aggregate',
  p.clicks
FROM public.partners_click p
ON CONFLICT (event_id) DO NOTHING;

-- ── Reconciliação ───────────────────────────────────────────────────────────
-- Falha a migration se o backfill não bater com a origem. Um backfill que
-- silenciosamente perde ou duplica linha é pior que um que não roda: a métrica
-- fica errada e ninguém percebe.
DO $reconcile$
DECLARE
  v_erc_origem   BIGINT;
  v_erc_destino  BIGINT;
  v_pc_origem    BIGINT;
  v_pc_destino   BIGINT;
BEGIN
  SELECT count(*) INTO v_erc_origem FROM public.external_redirect_clicks;
  SELECT count(*) INTO v_erc_destino
    FROM public.engagement_events WHERE source = 'legacy_external_redirect';

  SELECT coalesce(sum(clicks), 0) INTO v_pc_origem FROM public.partners_click;
  SELECT coalesce(sum(event_count), 0) INTO v_pc_destino
    FROM public.engagement_events WHERE source = 'legacy_partners_click_aggregate';

  IF v_erc_origem <> v_erc_destino THEN
    RAISE EXCEPTION 'backfill de redirects não reconciliou: origem=% destino=%',
      v_erc_origem, v_erc_destino;
  END IF;

  IF v_pc_origem <> v_pc_destino THEN
    RAISE EXCEPTION 'backfill de cliques de card não reconciliou: origem=% (SUM(clicks)) destino=% (SUM(event_count))',
      v_pc_origem, v_pc_destino;
  END IF;

  RAISE NOTICE 'reconciliação OK — % redirects, % cliques de card (em % linhas agregadas)',
    v_erc_destino, v_pc_destino,
    (SELECT count(*) FROM public.engagement_events WHERE source = 'legacy_partners_click_aggregate');
END
$reconcile$;

-- ── RPC de leitura para o admin (desbloqueia TP-4 4c) ───────────────────────
-- Publicada já sobre a fonte nova. O TP-4 pode construir a aba Clicks sem
-- esperar a instrumentação do app nem o corte das tabelas antigas.
CREATE OR REPLACE FUNCTION public.get_student_clicks_admin(
  p_user_id   UUID,
  p_page      INT DEFAULT 0,
  p_page_size INT DEFAULT 20
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total BIGINT;
  v_data  JSON;
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_student_clicks_admin: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_total
    FROM public.engagement_events e
   WHERE e.user_id = p_user_id;

  SELECT coalesce(json_agg(t), '[]'::json) INTO v_data FROM (
    SELECT
      e.id,
      e.event_type,
      e.occurred_at,
      e.entity_type,
      e.entity_id,
      e.unified_opportunity_id,
      e.destination_url,
      e.event_count,
      e.source,
      -- Nome legível resolvido aqui: a alternativa é o front fazer N+1 ida ao
      -- banco por linha da tabela.
      coalesce(po.name, inst.name) AS entity_name
    FROM public.engagement_events e
    LEFT JOIN public.partner_opportunities po
           ON e.entity_type = 'partner_opportunity' AND po.id = e.entity_id
    LEFT JOIN public.institutions inst
           ON e.entity_type = 'institution' AND inst.id = e.entity_id
    WHERE e.user_id = p_user_id
    ORDER BY e.occurred_at DESC, e.id
    LIMIT p_page_size OFFSET p_page * p_page_size
  ) t;

  RETURN json_build_object('data', v_data, 'count', v_total);
END;
$$;

COMMENT ON FUNCTION public.get_student_clicks_admin(UUID, INT, INT) IS
'Eventos de engajamento de um estudante, paginados, para a aba Clicks do modal de atividade (TP-4 4c). Lê engagement_events. Restrita ao backoffice.';

DO $acl$
DECLARE
  v_role TEXT;
BEGIN
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_student_clicks_admin(UUID, INT, INT) FROM PUBLIC';
  FOREACH v_role IN ARRAY ARRAY['anon', 'partner'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION public.get_student_clicks_admin(UUID, INT, INT) FROM %I', v_role);
    END IF;
  END LOOP;
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.get_student_clicks_admin(UUID, INT, INT) TO authenticated';
END
$acl$;
