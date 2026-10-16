-- Captura o comportamento das duas RPCs ANTES da migration, na mesma transação,
-- com as assinaturas antigas: (timestamptz, timestamptz, integer) e ().
-- Inclui dados reais do ambiente + fixtures: prova "filtro nulo preserva".
-- now() é fixo dentro da transação, então as janelas se repetem no assert.sql.

CREATE TEMP TABLE ccaf_baseline (k text PRIMARY KEY, v text, f timestamptz, t timestamptz, l int);

CREATE FUNCTION pg_temp.interest_text(p_from timestamptz, p_to timestamptz, p_limit int) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(concat_ws('|', r.opportunity_id, r.title, r.provider, r.clicks), ';' ORDER BY r.ord), '')
  FROM public.get_command_center_opportunity_interest(p_from, p_to, p_limit)
       WITH ORDINALITY AS r(opportunity_id, title, provider, clicks, ord)
$$;

INSERT INTO ccaf_baseline (k, v, f, t, l)
SELECT 'interest ' || w.k, pg_temp.interest_text(w.f, w.t, w.l), w.f, w.t, w.l
FROM (VALUES
  ('fixture window', '2031-01-01T00:00:00Z'::timestamptz, '2031-01-02T00:00:00Z'::timestamptz, 10),
  ('last 365d',      now() - interval '365 days',          now(),                                 100),
  ('all time',       '2000-01-01T00:00:00Z'::timestamptz, '2032-01-01T00:00:00Z'::timestamptz, 100)
) AS w(k, f, t, l);

INSERT INTO ccaf_baseline (k, v) VALUES
  ('demographics', public.get_command_center_demographics()::text);
