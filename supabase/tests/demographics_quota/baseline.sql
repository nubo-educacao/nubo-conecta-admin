-- Captura a RPC ANTES da migration (definição de 20261016140000), já com a
-- seed, na mesma transação: base para provar que o shape antigo continua
-- presente e que só raça/escola mudam, e só pela inferência por cota.

CREATE FUNCTION pg_temp.fingerprint() RETURNS text LANGUAGE sql AS $$
  SELECT md5(concat_ws('|',
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.id), '')) FROM public.user_profiles t),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.id), '')) FROM public.user_preferences t),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t.user_id), '')) FROM public.user_attribution t)
  ))
$$;

INSERT INTO nubrd92_snap VALUES
  ('old_all', public.get_command_center_demographics()::jsonb),
  ('old_q',   public.get_command_center_demographics(p_filter_campaign_id => '9b920000-0000-4000-a000-00000000000a')::jsonb),
  ('fp',      to_jsonb(pg_temp.fingerprint()));
