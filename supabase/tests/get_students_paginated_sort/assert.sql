\pset border 2
\echo '=== ORDENAÇÃO ==='

WITH cases(label, sb, so, expected) AS (VALUES
  ('full_name ASC',      'full_name',       'asc',  'Ana,Beatriz,Carlos,Daniel'),
  ('full_name DESC',     'full_name',       'desc', 'Daniel,Carlos,Beatriz,Ana'),
  ('age ASC (NULL last)','age',             'asc',  'Ana,Carlos,Daniel,Beatriz'),
  ('age DESC (NULL last)','age',            'desc', 'Daniel,Carlos,Ana,Beatriz'),
  ('whatsapp ASC',       'whatsapp',        'asc',  'Ana,Daniel,Carlos,Beatriz'),
  ('created_at DESC',    'created_at',      'desc', 'Beatriz,Carlos,Daniel,Ana'),
  ('city ASC',           'city',            'asc',  'Beatriz,Daniel,Carlos,Ana'),
  ('sort inválido→created_at DESC','naoexiste','desc','Beatriz,Carlos,Daniel,Ana')
)
SELECT
  label,
  expected,
  actual,
  CASE WHEN actual = expected THEN 'PASS' ELSE '*** FAIL ***' END AS result
FROM (
  SELECT label, expected,
    (SELECT string_agg(x->>'full_name', ',' ORDER BY ord)
     FROM json_array_elements(
            public.get_students_paginated(0,10,NULL,NULL,NULL,NULL,NULL,NULL,NULL,sb,so,NULL,NULL,NULL)->'data'
          ) WITH ORDINALITY AS a(x, ord)) AS actual
  FROM cases
) r;

\echo ''
\echo '=== PAGINAÇÃO ESTÁVEL (full_name asc, 2 por página) ==='

SELECT
  pg AS pagina,
  expected,
  actual,
  CASE WHEN actual = expected THEN 'PASS' ELSE '*** FAIL ***' END AS result
FROM (
  SELECT p.pg, p.expected,
    (SELECT string_agg(x->>'full_name', ',' ORDER BY ord)
     FROM json_array_elements(
            public.get_students_paginated(p.pg,2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'full_name','asc',NULL,NULL,NULL)->'data'
          ) WITH ORDINALITY AS a(x, ord)) AS actual
  FROM (VALUES (0,'Ana,Beatriz'), (1,'Carlos,Daniel')) AS p(pg, expected)
) r;

\echo ''
\echo '=== CONTAGEM TOTAL (não deve mudar com sort/paginação) ==='
SELECT
  (public.get_students_paginated(0,2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'age','asc',NULL,NULL,NULL)->>'count') AS count_pg0,
  CASE WHEN (public.get_students_paginated(0,2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'age','asc',NULL,NULL,NULL)->>'count') = '4'
       THEN 'PASS' ELSE '*** FAIL ***' END AS result;

\echo ''
\echo '=== FILTRO + ORDENAÇÃO COMBINADOS (idade >= 30, nome asc) ==='
SELECT
  expected, actual,
  CASE WHEN actual = expected THEN 'PASS' ELSE '*** FAIL ***' END AS result
FROM (
  SELECT 'Carlos,Daniel' AS expected,
    (SELECT string_agg(x->>'full_name', ',' ORDER BY ord)
     FROM json_array_elements(
            public.get_students_paginated(0,10,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'full_name','asc',NULL,30,NULL)->'data'
          ) WITH ORDINALITY AS a(x, ord)) AS actual
) r;
