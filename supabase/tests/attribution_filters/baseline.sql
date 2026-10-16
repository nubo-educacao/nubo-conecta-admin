-- Captura o comportamento das funções ANTES da migration, na mesma transação.
-- As chamadas são posicionais com as assinaturas antigas; depois da migration
-- as mesmas expressões resolvem para as novas (parâmetros novos em DEFAULT).
-- Inclui os dados reais do ambiente + fixtures: prova "filtro nulo preserva".

CREATE TEMP TABLE tp7_baseline (k text PRIMARY KEY, v text, sb text, so text, pg int);

INSERT INTO tp7_baseline (k, v, sb, so, pg)
SELECT 'page ' || s.sb || ' ' || s.so || ' p' || s.pg,
       (SELECT coalesce(string_agg(x->>'id', ',' ORDER BY ord), '')
        FROM json_array_elements(
               public.get_students_paginated(s.pg, 50, NULL, NULL, NULL, NULL, NULL, NULL, NULL, s.sb, s.so, NULL, NULL, NULL)->'data'
             ) WITH ORDINALITY AS a(x, ord)),
       s.sb, s.so, s.pg
FROM (VALUES ('created_at','desc',0), ('created_at','desc',1), ('full_name','asc',0), ('age','asc',2), ('whatsapp','desc',0)) AS s(sb, so, pg);

INSERT INTO tp7_baseline (k, v) VALUES
  ('students_count',
   public.get_students_paginated(0, 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'created_at', 'desc', NULL, NULL, NULL)->>'count'),
  ('students_count_name_tp7',
   public.get_students_paginated(0, 1, 'TP7FX', NULL, NULL, NULL, NULL, NULL, NULL, 'created_at', 'desc', NULL, NULL, NULL)->>'count'),
  ('stats_all',
   public.get_student_stats(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)::text),
  ('stats_state_pe',
   public.get_student_stats(NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'PE', NULL, NULL)::text),
  ('applications_all',
   -- created_at pode empatar e a RPC não desempata: compara o CONJUNTO.
   (SELECT coalesce(string_agg(r.id::text, ',' ORDER BY r.id), '')
    FROM public.get_student_applications_with_details(NULL) AS r));
