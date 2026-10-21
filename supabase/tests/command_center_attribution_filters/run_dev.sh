#!/usr/bin/env bash
# Teste dos filtros de campanha/divulgador (first-touch) do Command Center:
# migration 20261016140000_command_center_attribution_filters.sql e, desde o
# NUB-RD-93, as agregações das Edges em SQL (*_cc_attribution_sql_aggregates.sql,
# asserções em assert_aggregates.sql).
#
# Roda no DEV (yfgciamhzjvarwgzosto) numa ÚNICA transação que SEMPRE termina
# em exceção: fixtures → baseline com as funções ANTIGAS → migration →
# asserções → RAISE 'CCAF_ALL_PASS …' ou 'CCAF_FAIL …'. Nada persiste. O CLI
# mostra erro mesmo no sucesso; leia a mensagem. Nunca aponte para produção
# (fixture.sql também recusa ambientes com >1000 perfis).
#
#   bash supabase/tests/command_center_attribution_filters/run_dev.sh             # GREEN
#   bash supabase/tests/command_center_attribution_filters/run_dev.sh red         # sem a migration: deve falhar
#   bash supabase/tests/command_center_attribution_filters/run_dev.sh --with-tp7  # se o DEV ainda não tem
#        os helpers de 20261015202330 (matches_first_touch_attribution/assert_attribution_filter)
#
# Pré-requisitos no DEV: 20261009203000 e 20261015204255 aplicadas (as views de
# Match/demografia) e Supabase CLI autenticado (npx supabase@2.121.0 login).
#
# Para conferir que o teste pega regressões: troque first_touch_link_id por
# last_touch_link_id no JOIN de matches_first_touch_attribution, ou remova o
# `e.user_id IS NOT NULL` — verificações de campanha B / sem atribuição falham.
set -euo pipefail
cd "$(dirname "$0")/../../.."

REF=yfgciamhzjvarwgzosto
MODE=${1:-green}
DIR=supabase/tests/command_center_attribution_filters
MIGRATION=supabase/migrations/20261016140000_command_center_attribution_filters.sql
TP7=supabase/migrations/20261015202330_tp7_first_touch_attribution_filters.sql
AGGREGATES=$(ls supabase/migrations/*_cc_attribution_sql_aggregates.sql 2>/dev/null || true)
# 1 = o DEV já registra 20261016140000 (estado aplicado; ver o bloco da migration abaixo).
APPLIED_140000=$(npx -y supabase@2.121.0 db query --linked --project-ref "$REF" -o json \
  "select count(*) as n from supabase_migrations.schema_migrations where version = '20261016140000'" 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).rows[0].n))')
echo "20261016140000 no histórico do DEV: $APPLIED_140000 (1 = asserções sobre o estado aplicado)" >&2
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  echo "BEGIN;"
  # recusa qualquer alvo que não seja o DEV (PROD tem 2 jobs de cron)
  echo "DO \$\$ BEGIN IF (SELECT count(*) FROM public.user_profiles)>1000 OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id='781fe878-3d24-4061-8496-ac0ef3b627a5' AND email='backoffice@qa-s9.invalid') OR NOT coalesce((SELECT array_agg(jobname ORDER BY jobname) IN (ARRAY['check-program-deadlines']::text[],ARRAY['check-program-deadlines','user-activity-days-daily']::text[]) FROM cron.job),false) THEN RAISE EXCEPTION 'CCAF_ABORT: alvo não é o DEV'; END IF; END \$\$;"
  cat "$DIR/fixture.sql"
  cat "$DIR/baseline.sql"
  if [ "$MODE" = "--with-tp7" ]; then cat "$TP7"; fi
  cat <<'SQL'
DO $pre$ BEGIN
  IF to_regprocedure('public.matches_first_touch_attribution(uuid,uuid,uuid,boolean)') IS NULL
     OR to_regprocedure('public.assert_attribution_filter(uuid,uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION 'CCAF_FAIL pré-requisito: helpers do TP-7 (20261015202330) ausentes; rode com --with-tp7';
  END IF;
END $pre$;
SQL
  if [ "$MODE" != "red" ]; then
    # Com 20261016140000 já no histórico do DEV, reaplicá-la estoura 42723
    # (CREATE FUNCTION de assinatura existente). Nesse caso as asserções rodam
    # sobre o estado APLICADO e só a migration nova entra no bundle; o
    # "baseline" de interest/demographics passa a comparar a função vigente
    # consigo mesma (regressão da 9.0, não oráculo do NUB-RD-93).
    if [ "$APPLIED_140000" != "1" ]; then cat "$MIGRATION"; fi
    cat "$AGGREGATES"
  fi
  cat "$DIR/assert_aggregates.sql"
  cat "$DIR/assert.sql"
  echo "ROLLBACK;"
} > "$tmp"

out=$(npx -y supabase@2.121.0 db query --linked --project-ref "$REF" -f "$tmp" 2>&1 || true)
if grep -q 'CCAF_ALL_PASS' <<<"$out"; then
  grep -o 'CCAF_ALL_PASS[^"]*' <<<"$out"
  exit 0
fi
echo "$out" | grep -E 'CCAF_|ERROR|error' | sed 's/ | /\n  ✗ /g' | head -40
exit 1
