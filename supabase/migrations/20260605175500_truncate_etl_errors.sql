-- Truncate huge error logs to fix UI freezing
-- 20260605175500_truncate_etl_errors.sql

UPDATE public.etl_run_logs
SET errors = LEFT(errors, 1500) || '... [Erro longo truncado]'
WHERE LENGTH(errors) > 1500;
