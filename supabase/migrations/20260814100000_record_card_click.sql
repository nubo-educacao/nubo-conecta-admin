-- Registra card_click para usuário autenticado OU sessão anônima.
--
-- A escrita direta em engagement_events só é permitida a authenticated. O app
-- também precisa medir o clique que abre o modal de login; por isso o caminho
-- anônimo passa por esta RPC validada e limitada, no mesmo padrão de
-- record_card_views.

CREATE OR REPLACE FUNCTION public.record_card_click(
  p_event_id              TEXT,
  p_entity_type           TEXT,
  p_entity_id             UUID DEFAULT NULL,
  p_unified_opportunity_id TEXT DEFAULT NULL,
  p_source                TEXT DEFAULT 'card',
  p_anonymous_id          TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_max_per_hour CONSTANT INT := 300;

  v_user      UUID := auth.uid();
  v_anonymous TEXT := nullif(btrim(coalesce(p_anonymous_id, '')), '');
  v_event_id  TEXT := nullif(btrim(coalesce(p_event_id, '')), '');
  v_recent    INT;
  v_inserted  INT := 0;
BEGIN
  IF v_user IS NULL AND v_anonymous IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'subject');
  END IF;

  IF v_event_id IS NULL OR length(v_event_id) > 500 THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'event_id');
  END IF;

  IF p_entity_type NOT IN ('partner_opportunity', 'mec_opportunity') THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'entity_type');
  END IF;

  IF p_entity_id IS NULL
     AND nullif(btrim(coalesce(p_unified_opportunity_id, '')), '') IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid', 'field', 'entity');
  END IF;

  SELECT count(*) INTO v_recent
    FROM public.engagement_events
   WHERE event_type = 'card_click'
     AND entity_type IN ('partner_opportunity', 'mec_opportunity')
     AND occurred_at > now() - interval '1 hour'
     AND (
       (v_user IS NOT NULL AND user_id = v_user)
       OR (v_user IS NULL AND anonymous_id = v_anonymous)
     );

  IF v_recent >= c_max_per_hour THEN
    RETURN jsonb_build_object('status', 'throttled', 'inserted', 0);
  END IF;

  INSERT INTO public.engagement_events (
    event_id,
    event_type,
    occurred_at,
    user_id,
    anonymous_id,
    entity_type,
    entity_id,
    unified_opportunity_id,
    source,
    event_count
  ) VALUES (
    v_event_id,
    'card_click',
    now(),
    v_user,
    v_anonymous,
    p_entity_type,
    p_entity_id,
    nullif(btrim(coalesce(p_unified_opportunity_id, '')), ''),
    left(coalesce(nullif(btrim(coalesce(p_source, '')), ''), 'card'), 120),
    1
  )
  ON CONFLICT (event_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_inserted = 1 THEN 'created' ELSE 'duplicate' END,
    'inserted', v_inserted
  );
END;
$$;

COMMENT ON FUNCTION public.record_card_click(TEXT, TEXT, UUID, TEXT, TEXT, TEXT) IS
'Ingestão validada de card_click para usuário autenticado ou sessão anônima. Idempotente por event_id e limitada por sujeito.';

REVOKE EXECUTE ON FUNCTION public.record_card_click(TEXT, TEXT, UUID, TEXT, TEXT, TEXT)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_card_click(TEXT, TEXT, UUID, TEXT, TEXT, TEXT)
  TO anon, authenticated;

DO $acl$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'partner') THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.record_card_click(TEXT, TEXT, UUID, TEXT, TEXT, TEXT) FROM partner';
  END IF;
END
$acl$;
