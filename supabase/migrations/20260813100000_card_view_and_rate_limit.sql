-- TP-2 2a task 2 (card_view) + task 8 (rate limit na ingestão anônima)
-- Cards eeb42964, fbc7273e
--
-- ══ LACUNA 1 — ingestão anônima sem limite ══════════════════════════════════
-- A task 8 pede "endpoint server-side validado, com rate limit e idempotência —
-- nunca por INSERT público irrestrito". `resolve_channel_link` saiu com o
-- endpoint e a idempotência, mas SEM o limite: qualquer um podia chamá-la em
-- laço e inflar a contagem de cliques de qualquer link — justamente a métrica
-- que a produtização de canal existe para produzir.
--
-- ══ LACUNA 2 — card_view não existia ════════════════════════════════════════
-- O tipo estava no CHECK e nada o emitia. O plano dá a semântica: ≥50% do card
-- visível por ≥1s, deduplicado por sessão+entidade+janela. A detecção é do
-- cliente (IntersectionObserver); o que o banco garante é a deduplicação e o
-- teto de volume.
--
-- O estado compartilhado do rate limit é a própria engagement_events. Não
-- precisa de Redis: contar eventos recentes de um anonymous_id é uma query.

-- ── Índice que sustenta a contagem do rate limit ────────────────────────────
-- Sem ele, cada chamada faria varredura. O índice parcial por tempo mantém a
-- contagem barata mesmo com a tabela crescendo.
CREATE INDEX IF NOT EXISTS engagement_events_anon_recent_idx
  ON public.engagement_events (anonymous_id, event_type, occurred_at DESC)
  WHERE anonymous_id IS NOT NULL;

-- ── Rate limit em resolve_channel_link ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_channel_link(
  p_code         TEXT,
  p_anonymous_id TEXT,
  p_event_id     TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Um humano não clica em 30 links rastreados diferentes numa hora. O teto é
  -- ordens de grandeza acima do uso legítimo e só morde em abuso.
  c_max_per_hour CONSTANT INT := 30;

  v_link     RECORD;
  v_event_id TEXT;
  v_recent   INT;
BEGIN
  IF p_anonymous_id IS NULL OR btrim(p_anonymous_id) = '' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  SELECT l.id, l.code, l.destination_path, l.archived_at,
         l.utm_source, l.utm_medium, l.utm_campaign, l.utm_content, l.utm_term
    INTO v_link
    FROM public.channel_links l
   WHERE l.code = p_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  SELECT count(*) INTO v_recent
    FROM public.engagement_events
   WHERE anonymous_id = p_anonymous_id
     AND entity_type = 'channel_link'
     AND occurred_at > now() - interval '1 hour';

  v_event_id := coalesce(nullif(btrim(coalesce(p_event_id, '')), ''),
                         'link:' || v_link.id::text || ':' || p_anonymous_id || ':' ||
                         to_char(now(), 'YYYYMMDDHH24MISSMS'));

  -- Acima do teto: RESOLVE MESMO ASSIM, só não registra.
  -- Devolver 'rate_limited' mandaria a pessoa para a home. Se por trás do abuso
  -- houver um visitante real — NAT corporativo, escola, lan house — punir a
  -- navegação dele para proteger uma métrica é a troca errada. Perde-se o
  -- evento, não a visita.
  IF v_recent < c_max_per_hour THEN
    INSERT INTO public.engagement_events (
      event_id, event_type, occurred_at, anonymous_id,
      entity_type, channel_link_id, source, event_count
    ) VALUES (
      v_event_id, 'card_click', now(), p_anonymous_id,
      'channel_link', v_link.id, 'redirect_route', 1
    )
    ON CONFLICT (event_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'status',           'ok',
    'link_id',          v_link.id,
    'destination_path', coalesce(v_link.destination_path, '/'),
    'archived',         v_link.archived_at IS NOT NULL,
    'throttled',        v_recent >= c_max_per_hour,
    'utm', jsonb_strip_nulls(jsonb_build_object(
      'utm_source',   v_link.utm_source,
      'utm_medium',   v_link.utm_medium,
      'utm_campaign', v_link.utm_campaign,
      'utm_content',  v_link.utm_content,
      'utm_term',     v_link.utm_term
    ))
  );
END;
$$;

-- ── Ingestão de card_view, em lote ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_card_views(
  p_views        JSONB,
  p_anonymous_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Uma tela de catálogo mostra ~15 cards. Rolar por meia hora gera algumas
  -- centenas de views legítimas. 600/h dá folga e ainda barra automação.
  c_max_per_hour CONSTANT INT := 600;
  c_max_batch    CONSTANT INT := 50;

  v_user      UUID := auth.uid();
  v_subject   TEXT;
  v_recent    INT;
  v_inserted  INT := 0;
BEGIN
  IF jsonb_typeof(p_views) <> 'array' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  -- Um lote gigante é sinal de automação, não de navegação.
  IF jsonb_array_length(p_views) > c_max_batch THEN
    RETURN jsonb_build_object('status', 'batch_too_large');
  END IF;

  -- Autenticado é identificado pelo próprio id; anônimo, pela sessão.
  v_subject := coalesce(v_user::text, nullif(btrim(coalesce(p_anonymous_id, '')), ''));
  IF v_subject IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  SELECT count(*) INTO v_recent
    FROM public.engagement_events
   WHERE event_type = 'card_view'
     AND occurred_at > now() - interval '1 hour'
     AND (
       (v_user IS NOT NULL AND user_id = v_user)
       OR (v_user IS NULL AND anonymous_id = p_anonymous_id)
     );

  IF v_recent >= c_max_per_hour THEN
    RETURN jsonb_build_object('status', 'throttled', 'inserted', 0);
  END IF;

  -- A deduplicação real é o UNIQUE em event_id: o cliente monta a chave com
  -- sessão + entidade + janela de tempo, então rolar a mesma lista para cima e
  -- para baixo na mesma janela não multiplica o evento.
  WITH incoming AS (
    SELECT
      v.value ->> 'event_id'    AS event_id,
      v.value ->> 'entity_type' AS entity_type,
      nullif(v.value ->> 'entity_id', '')::uuid AS entity_id,
      nullif(v.value ->> 'unified_opportunity_id', '') AS unified_opportunity_id,
      coalesce(v.value ->> 'surface', 'unknown') AS surface
    FROM jsonb_array_elements(p_views) AS v(value)
  ),
  valid AS (
    SELECT * FROM incoming
     WHERE event_id IS NOT NULL
       AND entity_type IN ('partner_opportunity', 'mec_opportunity', 'institution', 'course')
       AND (entity_id IS NOT NULL OR unified_opportunity_id IS NOT NULL)
  ),
  ins AS (
    INSERT INTO public.engagement_events (
      event_id, event_type, occurred_at, user_id, anonymous_id,
      entity_type, entity_id, unified_opportunity_id, source, event_count
    )
    SELECT
      valid.event_id, 'card_view', now(), v_user,
      -- anonymous_id é gravado mesmo para autenticado: é o que permite ligar a
      -- navegação anterior ao login quando a costura roda.
      nullif(btrim(coalesce(p_anonymous_id, '')), ''),
      valid.entity_type, valid.entity_id, valid.unified_opportunity_id,
      'view:' || valid.surface, 1
    FROM valid
    ON CONFLICT (event_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_inserted FROM ins;

  RETURN jsonb_build_object('status', 'ok', 'inserted', v_inserted);
END;
$$;

COMMENT ON FUNCTION public.record_card_views(JSONB, TEXT) IS
'Ingestão em lote de card_view (TP-2 2a t2). Aceita autenticado e anônimo. A semântica de visibilidade (>=50% por >=1s) é detectada no cliente; aqui se garante deduplicação por event_id, teto de lote e rate limit por hora. Uma tela com 15 cards faz UMA chamada.';

DO $acl$
BEGIN
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.record_card_views(JSONB, TEXT) FROM PUBLIC';
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.record_card_views(JSONB, TEXT) TO anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.record_card_views(JSONB, TEXT) TO authenticated';
  END IF;
END
$acl$;
