-- Depois da reversão (20260811160000 + rollback_drop_views.sql): a RPC volta
-- byte a byte à definição anterior (hash normalizado medido em PROD e DEV em
-- 15/10/2026) e as views deixam de existir.
DO $rb$
BEGIN
  PERFORM pg_temp.ok(
    md5(regexp_replace(pg_get_functiondef('public.get_command_center_demographics()'::regprocedure), '\s', '', 'g')) = '19a44c39cb46a62045ec0fa8edac22e1',
    'reversão: RPC idêntica à de 20260811160000');
  PERFORM pg_temp.ok(to_regclass('public.vw_user_match_evidence') IS NULL AND to_regclass('public.vw_user_demographics_resolved') IS NULL,
    'reversão: views removidas');
  PERFORM set_config('request.jwt.claim.sub', (SELECT v FROM tp1c_ctx WHERE k = 'admin'), true);
  PERFORM pg_temp.ok(public.get_command_center_demographics()::jsonb->'match_health' ? 'with_match', 'reversão: RPC anterior responde');
END
$rb$;
