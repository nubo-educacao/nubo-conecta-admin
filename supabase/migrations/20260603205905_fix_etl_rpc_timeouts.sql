-- Fix statement timeouts for ETL RPCs handling thousands of rows
ALTER FUNCTION public.etl_import_prouni_base(uuid) SET statement_timeout = '10min';
ALTER FUNCTION public.etl_import_prouni_vacancies(uuid) SET statement_timeout = '10min';
ALTER FUNCTION public.etl_import_prouni_occupied(uuid) SET statement_timeout = '10min';
ALTER FUNCTION public.etl_import_sisu_base(uuid) SET statement_timeout = '10min';
ALTER FUNCTION public.etl_import_sisu_vacancies(uuid) SET statement_timeout = '10min';
ALTER FUNCTION public.etl_import_emec() SET statement_timeout = '10min';
