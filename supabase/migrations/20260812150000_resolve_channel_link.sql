-- TP-7 7B task 10 — resolução de /r/<code> + stitching de atribuição
-- Card fbc7273e · governance doc f74d1cd9 §3.3
--
-- A rota /r/<code> acontece ANTES do login. O visitante é anônimo, não tem
-- auth.uid(), e a policy de channel_links é restrita ao backoffice — ou seja,
-- ele não pode ler a tabela para descobrir o destino, e não pode inserir na
-- engagement_events para registrar o clique.
--
-- As duas operações entram por RPC SECURITY DEFINER. Mesmo padrão de
-- submit_partner_solicitation: a proteção não está em quem pode chamar (é uma
-- rota pública, tem que ser chamável), e sim no que a função aceita fazer.

-- ── Resolver o link e registrar o clique, numa ida só ────────────────────────
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
  v_link     RECORD;
  v_event_id TEXT;
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
    -- Não é erro do visitante: ele clicou num link que alguém distribuiu.
    -- O chamador manda para a home; aqui só se diz que não resolveu.
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  -- Link arquivado ainda RESOLVE e ainda registra o clique. Arquivar significa
  -- "não use mais em peça nova", não "quebre o que já está distribuído" — é a
  -- razão de os 22 códigos de unidade da USP terem sido arquivados e não
  -- deletados.
  v_event_id := coalesce(nullif(btrim(coalesce(p_event_id, '')), ''),
                         'link:' || v_link.id::text || ':' || p_anonymous_id || ':' ||
                         to_char(now(), 'YYYYMMDDHH24MISSMS'));

  INSERT INTO public.engagement_events (
    event_id, event_type, occurred_at, anonymous_id,
    entity_type, channel_link_id, source, event_count
  ) VALUES (
    v_event_id, 'card_click', now(), p_anonymous_id,
    'channel_link', v_link.id, 'redirect_route', 1
  )
  -- Idempotência: recarregar a página ou um retry de rede não vira clique novo.
  ON CONFLICT (event_id) DO NOTHING;

  RETURN jsonb_build_object(
    'status',           'ok',
    'link_id',          v_link.id,
    'destination_path', coalesce(v_link.destination_path, '/'),
    'archived',         v_link.archived_at IS NOT NULL,
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

COMMENT ON FUNCTION public.resolve_channel_link(TEXT, TEXT, TEXT) IS
'Resolve /r/<code> para destino + UTMs e registra o clique em engagement_events, tudo numa ida. Chamável por anônimo: a rota é pública por definição. Link arquivado ainda resolve — arquivar não pode quebrar peça já distribuída. TP-7 7B.';

-- ── Costurar a atribuição no login/cadastro ─────────────────────────────────
-- O clique é anônimo; a pessoa só ganha user_id depois. Esta função amarra os
-- dois usando o anonymous_id que o cookie carregou.
CREATE OR REPLACE FUNCTION public.attach_user_attribution(
  p_user_id      UUID,
  p_anonymous_id TEXT,
  p_first_code   TEXT DEFAULT NULL,
  p_last_code    TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_first_id UUID; v_last_id UUID;
  v_first_at TIMESTAMPTZ; v_last_at TIMESTAMPTZ;
BEGIN
  -- Só o próprio usuário costura a própria atribuição. Sem isto, qualquer
  -- autenticado poderia reescrever a origem de outra pessoa — e origem é o que
  -- decide a quem o cadastro é creditado.
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'attach_user_attribution: só o próprio usuário pode costurar sua atribuição'
      USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_first_id FROM public.channel_links WHERE code = p_first_code;
  SELECT id INTO v_last_id  FROM public.channel_links WHERE code = p_last_code;

  -- Retroceder ao histórico de eventos quando o cookie não trouxe os codes:
  -- é o caso de quem clicou, fechou o navegador e voltou depois.
  IF v_first_id IS NULL OR v_last_id IS NULL THEN
    SELECT min(occurred_at), max(occurred_at) INTO v_first_at, v_last_at
      FROM public.engagement_events
     WHERE anonymous_id = p_anonymous_id AND channel_link_id IS NOT NULL;

    IF v_first_id IS NULL THEN
      SELECT channel_link_id INTO v_first_id FROM public.engagement_events
       WHERE anonymous_id = p_anonymous_id AND channel_link_id IS NOT NULL
       ORDER BY occurred_at ASC LIMIT 1;
    END IF;

    IF v_last_id IS NULL THEN
      SELECT channel_link_id INTO v_last_id FROM public.engagement_events
       WHERE anonymous_id = p_anonymous_id AND channel_link_id IS NOT NULL
       ORDER BY occurred_at DESC LIMIT 1;
    END IF;
  END IF;

  IF v_first_id IS NULL AND v_last_id IS NULL THEN
    RETURN jsonb_build_object('status', 'no_attribution');
  END IF;

  -- Os eventos anônimos passam a pertencer à pessoa. Sem isto, o clique que
  -- trouxe o cadastro fica órfão e a taxa de conversão por link nunca fecha.
  UPDATE public.engagement_events
     SET user_id = p_user_id
   WHERE anonymous_id = p_anonymous_id AND user_id IS NULL;

  INSERT INTO public.user_attribution AS ua (
    user_id, first_touch_link_id, last_touch_link_id, first_touch_at, last_touch_at
  ) VALUES (
    p_user_id, v_first_id, v_last_id, coalesce(v_first_at, now()), coalesce(v_last_at, now())
  )
  ON CONFLICT (user_id) DO UPDATE SET
    -- FIRST TOUCH NUNCA É SOBRESCRITO. É o bug do middleware atual, que
    -- reescreve o cookie de referral a cada visita e por isso credita o
    -- cadastro ao último link em vez de a quem de fato trouxe a pessoa.
    last_touch_link_id = coalesce(EXCLUDED.last_touch_link_id, ua.last_touch_link_id),
    last_touch_at      = greatest(coalesce(EXCLUDED.last_touch_at, ua.last_touch_at), ua.last_touch_at),
    updated_at         = now();

  RETURN jsonb_build_object('status', 'ok',
                            'first_touch_link_id', v_first_id,
                            'last_touch_link_id', v_last_id);
END;
$$;

COMMENT ON FUNCTION public.attach_user_attribution(UUID, TEXT, TEXT, TEXT) IS
'Costura os eventos anônimos de um anonymous_id ao usuário recém-autenticado e grava user_attribution. First touch nunca é sobrescrito. TP-7 7B.';

DO $acl$
BEGIN
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.resolve_channel_link(TEXT,TEXT,TEXT) FROM PUBLIC';
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.attach_user_attribution(UUID,TEXT,TEXT,TEXT) FROM PUBLIC';

  -- resolve_channel_link é chamável por anônimo porque a rota é pública.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.resolve_channel_link(TEXT,TEXT,TEXT) TO anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.resolve_channel_link(TEXT,TEXT,TEXT) TO authenticated';
    -- attach_ exige sessão: o guard compara com auth.uid().
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.attach_user_attribution(UUID,TEXT,TEXT,TEXT) TO authenticated';
  END IF;
END
$acl$;
