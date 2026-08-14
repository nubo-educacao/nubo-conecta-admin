-- TP-7 7E task 16 — desempenho por campanha / canal / plataforma
-- Card fbc7273e · ADR-0028
--
-- Responde a pergunta em que canal é SUJEITO: "qual campanha performa melhor?".
-- O recorte em que canal é adjetivo ("quem veio deste canal?") são os filtros
-- nas telas existentes, escopo separado.
--
-- ⚠️ COLD START — LEIA ANTES DE INTERPRETAR QUALQUER TAXA
--   Cliques só começaram a ser gravados em 13/08/2026, quando engagement_events
--   entrou. Cadastros atribuídos existem desde março, vindos do backfill de
--   `referral_source`.
--
--   Ou seja: por algumas semanas o numerador está cheio e o denominador vazio.
--   Uma taxa de conversão ingênua mostraria percentual absurdo, divisão por
--   zero, ou — pior — 0% para campanhas que funcionaram bem, porque os cliques
--   delas aconteceram antes de existir instrumentação.
--
--   Por isso esta função NUNCA calcula taxa quando não há clique. Devolve
--   `conversion_rate = NULL` e `has_click_data = false`, e a tela é obrigada a
--   dizer isso em vez de imprimir um número. Se a primeira coisa que o
--   marketing vir for um número absurdo, a ferramenta perde a credibilidade
--   antes de ganhar.

CREATE OR REPLACE FUNCTION public.get_channel_performance(
  p_since DATE DEFAULT NULL,
  p_until DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
  v_from TIMESTAMPTZ := coalesce(p_since::timestamptz, '-infinity'::timestamptz);
  v_to   TIMESTAMPTZ := coalesce((p_until + 1)::timestamptz, 'infinity'::timestamptz);
BEGIN
  IF NOT public.is_backoffice_admin() THEN
    RAISE EXCEPTION 'get_channel_performance: acesso restrito ao backoffice'
      USING ERRCODE = '42501';
  END IF;

  WITH clicks AS (
    -- SUM(event_count) e não COUNT(*): linhas vindas de agregado legado
    -- representam N cliques numa linha só.
    SELECT e.channel_link_id, sum(e.event_count)::bigint AS clicks
    FROM public.engagement_events e
    WHERE e.channel_link_id IS NOT NULL
      AND e.occurred_at >= v_from AND e.occurred_at < v_to
    GROUP BY 1
  ),
  signups AS (
    -- FIRST touch: quem trouxe a pessoa. Creditar ao last touch faria o canal
    -- de reengajamento levar o mérito da aquisição.
    SELECT ua.first_touch_link_id AS link_id, count(*)::bigint AS signups
    FROM public.user_attribution ua
    WHERE ua.first_touch_link_id IS NOT NULL
      AND ua.first_touch_at >= v_from AND ua.first_touch_at < v_to
    GROUP BY 1
  ),
  matched AS (
    SELECT ua.first_touch_link_id AS link_id, count(DISTINCT ua.user_id)::bigint AS matched
    FROM public.user_attribution ua
    WHERE ua.first_touch_link_id IS NOT NULL
      AND ua.first_touch_at >= v_from AND ua.first_touch_at < v_to
      AND EXISTS (SELECT 1 FROM public.user_opportunity_matches m WHERE m.profile_id = ua.user_id)
    GROUP BY 1
  ),
  applied AS (
    -- status <> 'DRAFT': rascunho não é candidatura. `SUBMITTED` morreu em
    -- março e o que cresce hoje é `redirected`, então filtrar pelo negativo é
    -- o que sobrevive à mudança de vocabulário.
    SELECT ua.first_touch_link_id AS link_id, count(DISTINCT ua.user_id)::bigint AS applied
    FROM public.user_attribution ua
    WHERE ua.first_touch_link_id IS NOT NULL
      AND ua.first_touch_at >= v_from AND ua.first_touch_at < v_to
      AND EXISTS (
        SELECT 1 FROM public.student_applications sa
        WHERE sa.user_id = ua.user_id AND sa.status <> 'DRAFT'
      )
    GROUP BY 1
  ),
  per_link AS (
    SELECT
      l.id AS link_id,
      l.code,
      l.nickname,
      l.archived_at IS NOT NULL AS archived,
      c.id   AS campaign_id,
      c.name AS campaign_name,
      ch.id   AS channel_id,
      ch.name AS channel_name,
      ch.type AS medium,
      p.slug     AS platform_slug,
      p.name     AS platform_name,
      p.category AS platform_category,
      coalesce(cl.clicks, 0)   AS clicks,
      coalesce(s.signups, 0)   AS signups,
      coalesce(m.matched, 0)   AS matched,
      coalesce(a.applied, 0)   AS applied
    FROM public.channel_links l
    LEFT JOIN public.campaigns  c  ON c.id  = l.campaign_id
    JOIN      public.channels   ch ON ch.id = l.channel_id
    LEFT JOIN public.platforms  p  ON p.slug = l.platform_id
    LEFT JOIN clicks  cl ON cl.channel_link_id = l.id
    LEFT JOIN signups s  ON s.link_id  = l.id
    LEFT JOIN matched m  ON m.link_id  = l.id
    LEFT JOIN applied a  ON a.link_id  = l.id
  ),
  -- A taxa só existe onde há denominador. Sem clique, NULL — nunca 0, nunca
  -- infinito. É a regra que impede o cold start virar número mentiroso.
  scored AS (
    SELECT *,
      CASE WHEN clicks > 0 THEN round((signups::numeric / clicks) * 100, 1) END AS conversion_rate,
      clicks > 0 AS has_click_data
    FROM per_link
  )
  SELECT json_build_object(
    'links', (
      SELECT coalesce(json_agg(row_to_json(s) ORDER BY s.signups DESC, s.clicks DESC), '[]'::json)
      FROM scored s
    ),
    'by_campaign', (
      SELECT coalesce(json_agg(t ORDER BY t.signups DESC), '[]'::json) FROM (
        SELECT
          coalesce(campaign_name, 'Sem campanha') AS name,
          sum(clicks)  AS clicks,
          sum(signups) AS signups,
          sum(matched) AS matched,
          sum(applied) AS applied,
          count(*)     AS links,
          CASE WHEN sum(clicks) > 0
               THEN round((sum(signups)::numeric / sum(clicks)) * 100, 1) END AS conversion_rate
        FROM scored GROUP BY 1
      ) t
    ),
    'by_medium', (
      SELECT coalesce(json_agg(t ORDER BY t.signups DESC), '[]'::json) FROM (
        SELECT medium AS name, sum(clicks) AS clicks, sum(signups) AS signups,
               count(*) AS links,
               CASE WHEN sum(clicks) > 0
                    THEN round((sum(signups)::numeric / sum(clicks)) * 100, 1) END AS conversion_rate
        FROM scored GROUP BY 1
      ) t
    ),
    'by_platform', (
      SELECT coalesce(json_agg(t ORDER BY t.signups DESC), '[]'::json) FROM (
        SELECT coalesce(platform_name, 'Não informada') AS name,
               coalesce(platform_category, '—') AS category,
               sum(clicks) AS clicks, sum(signups) AS signups, count(*) AS links,
               CASE WHEN sum(clicks) > 0
                    THEN round((sum(signups)::numeric / sum(clicks)) * 100, 1) END AS conversion_rate
        FROM scored GROUP BY 1, 2
      ) t
    ),
    'totals', (
      SELECT json_build_object(
        'links',    count(*),
        'clicks',   coalesce(sum(clicks), 0),
        'signups',  coalesce(sum(signups), 0),
        'matched',  coalesce(sum(matched), 0),
        'applied',  coalesce(sum(applied), 0),
        -- A tela usa isto para decidir entre mostrar taxa ou explicar a
        -- ausência dela. Sem esta flag, "0 cliques" é indistinguível de
        -- "ninguém clicou", e são coisas muito diferentes.
        'has_any_click_data', coalesce(sum(clicks), 0) > 0,
        'first_click_at', (
          SELECT min(occurred_at) FROM public.engagement_events
          WHERE channel_link_id IS NOT NULL
        )
      ) FROM scored
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_channel_performance(DATE, DATE) IS
'Desempenho por campanha/canal/plataforma para a tela de Canais (TP-7 7E, ADR-0028). Cadastros são creditados ao FIRST touch. Taxa de conversão é NULL quando não há clique no período — nunca 0 — porque cliques só passaram a ser gravados em 13/08/2026 e uma taxa sem denominador seria mentirosa.';

DO $acl$
DECLARE v_role TEXT;
BEGIN
  EXECUTE 'REVOKE EXECUTE ON FUNCTION public.get_channel_performance(DATE, DATE) FROM PUBLIC';
  FOREACH v_role IN ARRAY ARRAY['anon', 'partner'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION public.get_channel_performance(DATE, DATE) FROM %I', v_role);
    END IF;
  END LOOP;
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.get_channel_performance(DATE, DATE) TO authenticated';
END
$acl$;
