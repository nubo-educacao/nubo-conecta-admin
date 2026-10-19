-- NUB-RD-93 (Sprint 9.1, TP-A) — recorte first-touch do Command Center em SQL
--
-- As Edges analytics-stats, analytics-activity e analytics-rankings resolviam
-- o recorte de campanha/divulgador em memória: paginavam user_attribution,
-- channel_links e user_profiles inteiros (resolveAttributedUserIds) e, mesmo
-- sem filtro, carregavam todo user_favorites/user_profiles/user_preferences.
-- Estas três RPCs fazem o recorte e as contagens no banco; cada Edge faz uma
-- única chamada e só monta a resposta (percentuais, normalização de nomes e
-- ordem das chaves continuam no TypeScript, com a mesma aritmética de antes).
--
-- Contrato do recorte, idêntico ao das Edges (e ao TP-7 / 20261016140000):
--   * campanha/divulgador: user_attribution.first_touch_link_id → channel_links
--     (AND no mesmo link; link arquivado continua valendo). Pessoa sem perfil
--     entra, como antes.
--   * "sem atribuição": perfis (user_profiles.id, inclusive dependentes) sem
--     linha em user_attribution ou com first-touch nulo — NOT EXISTS sobre o
--     mesmo universo que a Edge usava.
--   * com recorte, linhas sem user_id (mensagens anônimas) saem.
-- O conjunto é um CTE equivalente a public.matches_first_touch_attribution
-- (que tem SET search_path e não é "inlinada" pelo planner; chamada por linha
-- de chat_messages seria o mesmo gargalo de antes). A equivalência é provada
-- em supabase/tests/command_center_attribution_filters/assert_aggregates.sql
-- e em src/test/cc-attribution-aggregates-sql.test.ts.
--
-- Guard: service_role (as Edges, depois de authorizeBackoffice) ou
-- is_backoffice_admin(); senão 42501. Filtro incompatível, período, modo,
-- fuso ou tipo inválidos → 22023. Uma assinatura por nome; nenhum índice novo
-- (os de channel_links já existem; o EXPLAIN em PROD não pediu outro).
--
-- Produção: estas funções precisam existir ANTES do deploy das Edges novas
-- (merge em main aplica a migration; só depois o deploy manual das 3 Edges).
--
-- Reversão: DROP das três funções e redeploy das Edges de 4cb20f1b.

-- ─── cc_stats_aggregate ─────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.cc_stats_aggregate(timestamptz, timestamptz, timestamptz, boolean, uuid, uuid, boolean);

CREATE FUNCTION public.cc_stats_aggregate(
  p_from timestamptz,
  p_to timestamptz,
  p_prev_from timestamptz,
  p_with_history boolean DEFAULT false,
  p_filter_campaign_id uuid DEFAULT NULL,
  p_filter_channel_id uuid DEFAULT NULL,
  p_filter_unattributed boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_filtered boolean := p_filter_campaign_id IS NOT NULL
                     OR p_filter_channel_id IS NOT NULL
                     OR p_filter_unattributed IS TRUE;
  v_result jsonb;
BEGIN
  IF NOT (coalesce(auth.role(), '') = 'service_role' OR coalesce(public.is_backoffice_admin(), false)) THEN
    RAISE EXCEPTION 'cc_stats_aggregate: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_attribution_filter(p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);
  IF p_from IS NULL OR p_to IS NULL OR p_prev_from IS NULL OR p_to <= p_from OR p_prev_from > p_from THEN
    RAISE EXCEPTION 'Período inválido' USING ERRCODE = '22023';
  END IF;

  WITH allowed AS MATERIALIZED (
    SELECT up.id AS user_id FROM public.user_profiles up
     WHERE p_filter_unattributed IS TRUE
       AND NOT EXISTS (SELECT 1 FROM public.user_attribution ua
                        WHERE ua.user_id = up.id AND ua.first_touch_link_id IS NOT NULL)
    UNION ALL
    SELECT ua.user_id FROM public.user_attribution ua
      JOIN public.channel_links cl ON cl.id = ua.first_touch_link_id
     WHERE p_filter_unattributed IS NOT TRUE
       AND (p_filter_campaign_id IS NOT NULL OR p_filter_channel_id IS NOT NULL)
       AND (p_filter_campaign_id IS NULL OR cl.campaign_id = p_filter_campaign_id)
       AND (p_filter_channel_id IS NULL OR cl.channel_id = p_filter_channel_id)
  ),
  -- Mensagens do usuário (sender = 'user') de [p_prev_from, p_to).
  msgs AS MATERIALIZED (
    SELECT m.user_id, m.created_at, m.created_at >= p_from AS is_current
      FROM public.chat_messages m
     WHERE m.sender = 'user' AND m.created_at >= p_prev_from AND m.created_at < p_to
       AND (NOT v_filtered OR m.user_id IN (SELECT a.user_id FROM allowed a))
  ),
  msg_users AS (
    SELECT DISTINCT user_id, is_current FROM msgs WHERE user_id IS NOT NULL
  ),
  favs AS MATERIALIZED (
    SELECT f.user_id, f.created_at FROM public.user_favorites f
     WHERE NOT v_filtered OR f.user_id IN (SELECT a.user_id FROM allowed a)
  ),
  -- Catálogo: favoritou ou atualizou preferências na janela sem ter mandado mensagem nela.
  catalog AS (
    SELECT DISTINCT c.user_id, c.is_current FROM (
      SELECT f.user_id, f.created_at >= p_from AS is_current FROM favs f
       WHERE f.created_at >= p_prev_from AND f.created_at < p_to
      UNION ALL
      SELECT p.user_id, p.updated_at >= p_from FROM public.user_preferences p
       WHERE p.updated_at >= p_prev_from AND p.updated_at < p_to
         AND (NOT v_filtered OR p.user_id IN (SELECT a.user_id FROM allowed a))
    ) c
     WHERE c.user_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM msg_users mu WHERE mu.user_id = c.user_id AND mu.is_current = c.is_current)
  ),
  -- Sessões: nova sessão quando o intervalo passa de 30 min, em milissegundos
  -- truncados (a precisão de Date.parse que a Edge usava).
  sessions AS (
    SELECT g.user_id, g.is_current, 1 + count(*) FILTER (WHERE g.gap > 1800000) AS sessions
      FROM (SELECT s.user_id, s.is_current,
                   s.ms - lag(s.ms) OVER (PARTITION BY s.user_id, s.is_current ORDER BY s.ms) AS gap
              FROM (SELECT user_id, is_current, floor(extract(epoch FROM created_at) * 1000) AS ms
                      FROM msgs WHERE user_id IS NOT NULL) s) g
     GROUP BY g.user_id, g.is_current
  ),
  power AS (SELECT * FROM sessions WHERE sessions >= 2),
  top_power AS (
    SELECT p.user_id, p.sessions, coalesce(nullif(up.full_name, ''), 'Usuário sem perfil') AS user_name
      FROM power p LEFT JOIN public.user_profiles up ON up.id = p.user_id
     WHERE p.is_current
     ORDER BY p.sessions DESC, p.user_id::text COLLATE "C"
     LIMIT 50
  )
  SELECT jsonb_build_object(
    -- Perfis do recorte. "Sem atribuição" já é um conjunto de user_profiles.id
    -- distintos; no recorte por link, só quem tem perfil.
    'total_registered', CASE WHEN v_filtered THEN
        (SELECT count(*) FROM allowed a
          WHERE p_filter_unattributed IS TRUE
             OR EXISTS (SELECT 1 FROM public.user_profiles up WHERE up.id = a.user_id)) END,
    'current_messages', (SELECT count(*) FROM msgs WHERE is_current),
    'previous_messages', (SELECT count(*) FROM msgs WHERE NOT is_current),
    'history_messages', CASE WHEN p_with_history IS TRUE THEN
        (SELECT count(*) FROM public.chat_messages m
          WHERE m.sender = 'user' AND (NOT v_filtered OR m.user_id IN (SELECT a.user_id FROM allowed a))) END,
    'message_users', (SELECT count(*) FROM msg_users WHERE is_current),
    'previous_message_users', (SELECT count(*) FROM msg_users WHERE NOT is_current),
    'catalog_users', (SELECT count(*) FROM catalog WHERE is_current),
    'previous_catalog_users', (SELECT count(*) FROM catalog WHERE NOT is_current),
    'current_favorites', (SELECT count(*) FROM favs WHERE created_at >= p_from AND created_at < p_to),
    'previous_favorites', (SELECT count(*) FROM favs WHERE created_at >= p_prev_from AND created_at < p_from),
    'history_favorites', CASE WHEN p_with_history IS TRUE THEN (SELECT count(*) FROM favs) END,
    'power_users', (SELECT count(*) FROM power WHERE is_current),
    'previous_power_users', (SELECT count(*) FROM power WHERE NOT is_current),
    'power_users_list', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'user_id', t.user_id, 'user_name', t.user_name, 'access_count', t.sessions)
        ORDER BY t.sessions DESC, t.user_id::text COLLATE "C") FROM top_power t), '[]'::jsonb)
  ) INTO v_result;
  RETURN v_result;
END;
$$;

-- ─── cc_activity_aggregate ──────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.cc_activity_aggregate(text, timestamptz, timestamptz, text, integer, uuid, uuid, boolean);

CREATE FUNCTION public.cc_activity_aggregate(
  p_mode text,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_time_zone text DEFAULT 'America/Sao_Paulo',
  p_zoom_hour integer DEFAULT NULL,
  p_filter_campaign_id uuid DEFAULT NULL,
  p_filter_channel_id uuid DEFAULT NULL,
  p_filter_unattributed boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_filtered boolean := p_filter_campaign_id IS NOT NULL
                     OR p_filter_channel_id IS NOT NULL
                     OR p_filter_unattributed IS TRUE;
  v_tz text := coalesce(p_time_zone, 'America/Sao_Paulo');
  v_ranged boolean := p_from IS NOT NULL;
  v_zoom integer := CASE WHEN p_mode = 'day' THEN p_zoom_hour END;
  v_now timestamptz := now();
  v_today date;
  v_start date;
  v_result jsonb;
BEGIN
  IF NOT (coalesce(auth.role(), '') = 'service_role' OR coalesce(public.is_backoffice_admin(), false)) THEN
    RAISE EXCEPTION 'cc_activity_aggregate: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_attribution_filter(p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);
  IF p_mode IS NULL OR p_mode NOT IN ('week', 'day', 'total')
     OR (p_zoom_hour IS NOT NULL AND p_zoom_hour NOT BETWEEN 0 AND 23) THEN
    RAISE EXCEPTION 'Modo de atividade inválido' USING ERRCODE = '22023';
  END IF;
  IF (p_from IS NULL) <> (p_to IS NULL) OR p_to <= p_from THEN
    RAISE EXCEPTION 'Período inválido' USING ERRCODE = '22023';
  END IF;
  BEGIN
    v_today := (v_now AT TIME ZONE v_tz)::date;
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE EXCEPTION 'Fuso horário inválido' USING ERRCODE = '22023';
  END;
  -- Sem período: hoje (day), últimos 7 dias (week) ou todo o histórico (total), no fuso pedido.
  v_start := CASE WHEN p_mode = 'day' THEN v_today ELSE v_today - 6 END;

  WITH allowed AS MATERIALIZED (
    SELECT up.id AS user_id FROM public.user_profiles up
     WHERE p_filter_unattributed IS TRUE
       AND NOT EXISTS (SELECT 1 FROM public.user_attribution ua
                        WHERE ua.user_id = up.id AND ua.first_touch_link_id IS NOT NULL)
    UNION ALL
    SELECT ua.user_id FROM public.user_attribution ua
      JOIN public.channel_links cl ON cl.id = ua.first_touch_link_id
     WHERE p_filter_unattributed IS NOT TRUE
       AND (p_filter_campaign_id IS NOT NULL OR p_filter_channel_id IS NOT NULL)
       AND (p_filter_campaign_id IS NULL OR cl.campaign_id = p_filter_campaign_id)
       AND (p_filter_channel_id IS NULL OR cl.channel_id = p_filter_channel_id)
  ),
  sel AS MATERIALIZED (
    SELECT m.user_id, (m.created_at AT TIME ZONE v_tz) AS lt
      FROM public.chat_messages m
     WHERE m.sender = 'user'
       AND (NOT v_filtered OR m.user_id IN (SELECT a.user_id FROM allowed a))
       AND ((v_ranged AND m.created_at >= p_from AND m.created_at < p_to)
         OR (NOT v_ranged AND m.created_at < v_now
             AND (m.created_at AT TIME ZONE v_tz)::date <= v_today
             -- superconjunto em UTC (fusos até ±24h) + corte exato no calendário local
             AND (p_mode = 'total' OR (m.created_at >= ((v_start - 1)::timestamp AT TIME ZONE 'UTC')
                                       AND (m.created_at AT TIME ZONE v_tz)::date >= v_start))))
  ),
  span AS (
    SELECT CASE WHEN v_ranged THEN (p_from AT TIME ZONE v_tz)::date
                WHEN p_mode = 'total' THEN coalesce((SELECT min(s.lt)::date FROM sel s), v_today)
                ELSE v_start END AS first_day,
           CASE WHEN v_ranged THEN ((p_to - interval '1 millisecond') AT TIME ZONE v_tz)::date
                ELSE v_today END AS last_day
  ),
  buckets AS (
    SELECT h AS ord, h::text AS k, lpad(h::text, 2, '0') || 'h' AS label
      FROM generate_series(0, 23) h
     WHERE p_mode = 'day' AND v_zoom IS NULL
    UNION ALL
    SELECT mi, mi::text, lpad(v_zoom::text, 2, '0') || ':' || lpad(mi::text, 2, '0')
      FROM generate_series(0, 45, 15) mi
     WHERE p_mode = 'day' AND v_zoom IS NOT NULL
    UNION ALL
    SELECT d::date - s.first_day, to_char(d, 'YYYY-MM-DD'),
           to_char(d, 'DD/MM') || CASE WHEN to_char(s.first_day, 'YYYY') <> to_char(s.last_day, 'YYYY')
                                       THEN '/' || to_char(d, 'YYYY') ELSE '' END
      FROM span s, generate_series(s.first_day::timestamp, s.last_day::timestamp, interval '1 day') d
     WHERE p_mode <> 'day'
  ),
  keyed AS (
    SELECT s.user_id,
           CASE WHEN p_mode <> 'day' THEN to_char(s.lt, 'YYYY-MM-DD')
                WHEN v_zoom IS NULL THEN extract(hour FROM s.lt)::int::text
                WHEN extract(hour FROM s.lt)::int = v_zoom THEN (floor(extract(minute FROM s.lt) / 15) * 15)::int::text
           END AS k
      FROM sel s
  ),
  counts AS (
    SELECT k, count(*) AS n, count(DISTINCT user_id) AS u FROM keyed WHERE k IS NOT NULL GROUP BY k
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'label', b.label, 'mensagens', coalesce(c.n, 0), 'usuarios', coalesce(c.u, 0)) ORDER BY b.ord), '[]'::jsonb)
    INTO v_result
    FROM buckets b LEFT JOIN counts c ON c.k = b.k;
  RETURN v_result;
END;
$$;

-- ─── cc_rankings_aggregate ──────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.cc_rankings_aggregate(text, timestamptz, timestamptz, uuid, uuid, boolean);

CREATE FUNCTION public.cc_rankings_aggregate(
  p_type text,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_filter_campaign_id uuid DEFAULT NULL,
  p_filter_channel_id uuid DEFAULT NULL,
  p_filter_unattributed boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_filtered boolean := p_filter_campaign_id IS NOT NULL
                     OR p_filter_channel_id IS NOT NULL
                     OR p_filter_unattributed IS TRUE;
  v_result jsonb;
BEGIN
  IF NOT (coalesce(auth.role(), '') = 'service_role' OR coalesce(public.is_backoffice_admin(), false)) THEN
    RAISE EXCEPTION 'cc_rankings_aggregate: acesso restrito ao backoffice' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_attribution_filter(p_filter_campaign_id, p_filter_channel_id, p_filter_unattributed);
  IF p_type IS NULL OR p_type NOT IN ('users', 'locations', 'courses', 'preferences', 'location_preferences') THEN
    RAISE EXCEPTION 'Tipo de ranking inválido' USING ERRCODE = '22023';
  END IF;

  IF p_type = 'users' THEN
    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
      RAISE EXCEPTION 'Período inválido' USING ERRCODE = '22023';
    END IF;
    -- Top 100 por mensagens do usuário na janela; desempate pelo id.
    WITH allowed AS MATERIALIZED (
      SELECT up.id AS user_id FROM public.user_profiles up
       WHERE p_filter_unattributed IS TRUE
         AND NOT EXISTS (SELECT 1 FROM public.user_attribution ua
                          WHERE ua.user_id = up.id AND ua.first_touch_link_id IS NOT NULL)
      UNION ALL
      SELECT ua.user_id FROM public.user_attribution ua
        JOIN public.channel_links cl ON cl.id = ua.first_touch_link_id
       WHERE p_filter_unattributed IS NOT TRUE
         AND (p_filter_campaign_id IS NOT NULL OR p_filter_channel_id IS NOT NULL)
         AND (p_filter_campaign_id IS NULL OR cl.campaign_id = p_filter_campaign_id)
         AND (p_filter_channel_id IS NULL OR cl.channel_id = p_filter_channel_id)
    ),
    msgs AS (
      SELECT m.user_id, floor(extract(epoch FROM m.created_at) * 1000) AS ms
        FROM public.chat_messages m
       WHERE m.sender = 'user' AND m.created_at >= p_from AND m.created_at < p_to AND m.user_id IS NOT NULL
         AND (NOT v_filtered OR m.user_id IN (SELECT a.user_id FROM allowed a))
    ),
    per AS (
      SELECT g.user_id, count(*) AS messages, 1 + count(*) FILTER (WHERE g.gap > 1800000) AS sessions
        FROM (SELECT user_id, ms - lag(ms) OVER (PARTITION BY user_id ORDER BY ms) AS gap FROM msgs) g
       GROUP BY g.user_id
    ),
    top AS (
      SELECT * FROM per ORDER BY messages DESC, user_id::text COLLATE "C" LIMIT 100
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', t.user_id,
             'name', coalesce(nullif(up.full_name, ''), 'Usuário sem perfil'),
             'messages', t.messages,
             'favorites', (SELECT count(*) FROM public.user_favorites f WHERE f.user_id = t.user_id),
             'sessions', t.sessions,
             'score', t.messages)
           ORDER BY t.messages DESC, t.user_id::text COLLATE "C"), '[]'::jsonb)
      INTO v_result
      FROM top t LEFT JOIN public.user_profiles up ON up.id = t.user_id;
    RETURN v_result;
  END IF;

  -- Demais rankings: grupos pelo valor CRU, na ordem da primeira aparência
  -- (linhas por id, itens do array na ordem). A Edge normaliza os nomes e
  -- soma os grupos que viram o mesmo rótulo — mesma regra (e mesmo motor de
  -- maiúsculas/minúsculas) de antes. `total` = linhas com o campo preenchido.
  WITH allowed AS MATERIALIZED (
    SELECT up.id AS user_id FROM public.user_profiles up
     WHERE p_filter_unattributed IS TRUE
       AND NOT EXISTS (SELECT 1 FROM public.user_attribution ua
                        WHERE ua.user_id = up.id AND ua.first_touch_link_id IS NOT NULL)
    UNION ALL
    SELECT ua.user_id FROM public.user_attribution ua
      JOIN public.channel_links cl ON cl.id = ua.first_touch_link_id
     WHERE p_filter_unattributed IS NOT TRUE
       AND (p_filter_campaign_id IS NOT NULL OR p_filter_channel_id IS NOT NULL)
       AND (p_filter_campaign_id IS NULL OR cl.campaign_id = p_filter_campaign_id)
       AND (p_filter_channel_id IS NULL OR cl.channel_id = p_filter_channel_id)
  ),
  source_rows AS (
    SELECT up.id AS row_id, up.id AS person, ARRAY[up.city] AS vals
      FROM public.user_profiles up WHERE p_type = 'locations' AND up.city IS NOT NULL
    UNION ALL
    SELECT p.id, p.user_id, p.course_interest
      FROM public.user_preferences p WHERE p_type = 'courses' AND p.course_interest IS NOT NULL
    UNION ALL
    SELECT p.id, p.user_id, ARRAY[p.program_preference]
      FROM public.user_preferences p WHERE p_type = 'preferences' AND p.program_preference IS NOT NULL
    UNION ALL
    SELECT p.id, p.user_id, ARRAY[p.location_preference]
      FROM public.user_preferences p WHERE p_type = 'location_preferences' AND p.location_preference IS NOT NULL
  ),
  kept AS MATERIALIZED (
    SELECT r.* FROM source_rows r
     WHERE NOT v_filtered OR r.person IN (SELECT a.user_id FROM allowed a)
  ),
  items AS (
    SELECT e.value, row_number() OVER (ORDER BY k.row_id, e.ord) AS seq
      FROM kept k CROSS JOIN LATERAL unnest(k.vals) WITH ORDINALITY AS e(value, ord)
     WHERE e.value IS NOT NULL
  ),
  grouped AS (
    SELECT value, count(*) AS n, min(seq) AS first_seq FROM items GROUP BY value
  )
  SELECT jsonb_build_object(
           'total', (SELECT count(*) FROM kept),
           'groups', coalesce((SELECT jsonb_agg(jsonb_build_object('value', g.value, 'count', g.n) ORDER BY g.first_seq)
                                 FROM grouped g), '[]'::jsonb))
    INTO v_result;
  RETURN v_result;
END;
$$;

-- ─── ACL (padrão de 20261016140000) ─────────────────────────────────────────

REVOKE ALL ON FUNCTION public.cc_stats_aggregate(timestamptz, timestamptz, timestamptz, boolean, uuid, uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cc_activity_aggregate(text, timestamptz, timestamptz, text, integer, uuid, uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cc_rankings_aggregate(text, timestamptz, timestamptz, uuid, uuid, boolean) FROM PUBLIC, anon;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'partner') THEN
    REVOKE ALL ON FUNCTION public.cc_stats_aggregate(timestamptz, timestamptz, timestamptz, boolean, uuid, uuid, boolean) FROM partner;
    REVOKE ALL ON FUNCTION public.cc_activity_aggregate(text, timestamptz, timestamptz, text, integer, uuid, uuid, boolean) FROM partner;
    REVOKE ALL ON FUNCTION public.cc_rankings_aggregate(text, timestamptz, timestamptz, uuid, uuid, boolean) FROM partner;
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.cc_stats_aggregate(timestamptz, timestamptz, timestamptz, boolean, uuid, uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cc_activity_aggregate(text, timestamptz, timestamptz, text, integer, uuid, uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cc_rankings_aggregate(text, timestamptz, timestamptz, uuid, uuid, boolean) TO authenticated, service_role;

COMMENT ON FUNCTION public.cc_stats_aggregate(timestamptz, timestamptz, timestamptz, boolean, uuid, uuid, boolean) IS
  'NUB-RD-93: contagens de analytics-stats (mensagens sender=user, ativos, catálogo, recorrentes, favoritos) em [p_prev_from,p_to), com recorte first-touch opcional. A Edge calcula as variações percentuais.';
COMMENT ON FUNCTION public.cc_activity_aggregate(text, timestamptz, timestamptz, text, integer, uuid, uuid, boolean) IS
  'NUB-RD-93: buckets {label, mensagens, usuarios} de analytics-activity (dia/hora/15 min) no fuso pedido, com recorte first-touch opcional.';
COMMENT ON FUNCTION public.cc_rankings_aggregate(text, timestamptz, timestamptz, uuid, uuid, boolean) IS
  'NUB-RD-93: ranking de usuários (top 100) ou grupos crus de cidade/curso/programa/local por ordem de primeira aparência, com recorte first-touch opcional. A Edge normaliza nomes e corta o top N.';
